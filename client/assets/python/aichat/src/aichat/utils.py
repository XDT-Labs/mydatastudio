"""
Utility functions for file operations, path management, and archive handling.

This module provides helper functions for managing model files, including
path generation, archive extraction, and model downloading from Hugging Face Hub.
"""
import os
import tarfile
import urllib.request
from typing import Optional


def get_local_path(model_id: str) -> str:
    """
    Generate a local directory path for storing a model.
    
    Converts a Hugging Face model ID into a safe local directory path
    by replacing forward slashes with hyphens and adding a suffix.
    
    Args:
        model_id (str): Hugging Face model identifier (e.g., 'google/gemma-2-9b-it')
        
    Returns:
        str: Local directory path (e.g., '../models/google-gemma-2-9b-it-local/')
        
    Example:
        >>> get_local_path("google/gemma-2-9b-it")
        './models/google-gemma-2-9b-it-local/'
    """
    # Use a sanitized version of the model ID for the directory name
    safe_model_name = model_id.replace('/', '-')
    return f"./models/{safe_model_name}-local/"


def get_local_zip_path(model_id: str) -> str:
    """
    Generate a local archive file path for a model.
    
    Creates a standardized path for model archive files based on the
    model ID, using tar.gz format for compression.
    
    Args:
        model_id (str): Hugging Face model identifier
        
    Returns:
        str: Local archive file path (e.g., './models/google-gemma-2-9b-it-local.tar.gz')
        
    Example:
        >>> get_local_zip_path("google/gemma-2-9b-it")
        './models/google-gemma-2-9b-it-local.tar.gz'
    """
    # Use a sanitized version of the model ID for the directory name
    safe_model_name = model_id.replace('/', '-')
    return f"./models/{safe_model_name}-local.tar.gz"


def handle_local_archive(archive_path: str, target_dir: str) -> bool:
    """
    Extract a local archive file to the specified target directory.
    
    Supports tar archives with various compression formats (tar, tar.gz, tar.bz2, etc.).
    Creates the target directory if it doesn't exist.
    
    Args:
        archive_path (str): Path to the archive file to extract
        target_dir (str): Directory where files should be extracted
        
    Returns:
        bool: True if extraction was successful, False otherwise
        
    Example:
        >>> handle_local_archive("./model.tar.gz", "./model/")
        True
    """
    if not os.path.exists(archive_path):
        return False
        
    print(f"[LOADER] Found archive at {archive_path}. Extracting...")
    try:
        # Create the target directory
        os.makedirs(target_dir, exist_ok=True)
        
        # Extract the archive (auto-detects compression format)
        with tarfile.open(archive_path, 'r:*') as tar:
            tar.extractall(path=target_dir)
        
        print(f"[LOADER] Archive extraction complete to {target_dir}.")
        return True
        
    except Exception as extract_error:
        print(f"[ERROR] Failed to extract {archive_path}: {extract_error}")
        return False


def find_local_model(filename: str, local_path: str) -> Optional[str]:
    """
    Search for a GGUF model file across all known local locations.

    Checks the following locations in order:
    1. PyInstaller _MEIPASS bundle directory (onefile builds)
    2. The '_internal/models/' folder next to the executable (onedir/COLLECT builds)
    3. The explicit local_path directory

    For bundled paths, also does a fuzzy match on the filename to handle
    prefix differences (e.g. 'google_gemma-3-4b-it-Q4_K_M.gguf' vs 'gemma-3-4b-it-Q4_K_M.gguf').

    Args:
        filename (str): The GGUF filename to search for.
        local_path (str): Fallback directory to check.

    Returns:
        Optional[str]: Absolute path to the model file, or None if not found.
    """
    import sys

    def _fuzzy_find(directory: str, target_filename: str) -> Optional[str]:
        """Find a file in directory that exactly matches or contains target_filename as substring."""
        if not os.path.isdir(directory):
            return None
        # Exact match first
        exact = os.path.join(directory, target_filename)
        if os.path.exists(exact):
            return exact
        # Fuzzy: find any .gguf file whose name contains the target (handles prefix differences)
        for f in os.listdir(directory):
            if f.endswith('.gguf') and target_filename in f:
                found = os.path.join(directory, f)
                print(f"[LOADER] Fuzzy-matched bundled model: {f}")
                return found
        return None

    # 1. PyInstaller onefile: sys._MEIPASS/models/
    if getattr(sys, 'frozen', False) and hasattr(sys, '_MEIPASS'):
        meipass_models = os.path.join(sys._MEIPASS, 'models')
        print(f"[LOADER] Checking _MEIPASS bundle: {meipass_models}")
        found = _fuzzy_find(meipass_models, filename)
        if found:
            print(f"[LOADER] Found model in _MEIPASS: {found}")
            return found

    # 2. PyInstaller onedir/COLLECT: <exe_dir>/_internal/models/
    if getattr(sys, 'frozen', False):
        exe_dir = os.path.dirname(sys.executable)
        internal_models = os.path.join(exe_dir, '_internal', 'models')
        print(f"[LOADER] Checking _internal/models bundle: {internal_models}")
        found = _fuzzy_find(internal_models, filename)
        if found:
            print(f"[LOADER] Found model in _internal/models: {found}")
            return found

    # 3. Explicit local_path (user-downloaded models)
    print(f"[LOADER] Checking local path: {local_path}")
    found = _fuzzy_find(local_path, filename)
    if found:
        print(f"[LOADER] Found model at local path: {found}")
        return found

    return None


def download_gguf_model(model_id: str, filename: str, local_path: str) -> str:
    """
    Download a GGUF model from Hugging Face Hub into local_path.

    This should only be called explicitly (e.g., from the /download-model endpoint),
    never automatically at startup.

    Args:
        model_id (str): Hugging Face model repository identifier.
        filename (str): The specific GGUF filename to download.
        local_path (str): Target directory for the downloaded file.

    Returns:
        str: Absolute path to the downloaded .gguf file.

    Raises:
        Exception: If the download fails.
    """
    from huggingface_hub import hf_hub_download

    print(f"[LOADER] Downloading {filename} from {model_id} into {local_path}...")
    os.makedirs(local_path, exist_ok=True)
    downloaded_path = hf_hub_download(
        repo_id=model_id,
        filename=filename,
        local_dir=local_path
    )
    print(f"[LOADER] Download complete: {downloaded_path}")
    return downloaded_path


def download_gguf_model_if_needed(model_id: str, filename: str, local_path: str) -> str:
    """
    DEPRECATED: Use find_local_model() + download_gguf_model() separately.

    Kept for backward compatibility. Finds an existing model or downloads it.
    """
    found = find_local_model(filename, local_path)
    if found:
        return found
    return download_gguf_model(model_id, filename, local_path)
