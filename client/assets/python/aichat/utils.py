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
        str: Local directory path (e.g., './models/google-gemma-2-9b-it-local/')
        
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


def download_model_if_needed(model_id: str, local_path: str, custom_archive_path: Optional[str] = None) -> bool:
    """
    Ensure a model is available locally, downloading if necessary.
    
    This function implements a fallback strategy:
    1. Check if model directory already exists and has files
    2. Try to extract from custom archive path (if provided)
    3. Try to extract from standard archive paths (.tar.gz, .tgz, .tar)
    4. Download from Hugging Face Hub as last resort
    
    Args:
        model_id (str): Hugging Face model identifier
        local_path (str): Target directory for the model files
        custom_archive_path (Optional[str]): Optional path to a specific archive file
        
    Returns:
        bool: True if model is available locally, False if all methods failed
        
    Example:
        >>> download_model_if_needed("google/gemma-2-9b-it", "./model/")
        True
    """
    from huggingface_hub import snapshot_download
    
    # Check if model directory already exists and has files
    if not os.path.exists(local_path) or not os.listdir(local_path):
        print(f"[LOADER] Local model not found at {local_path}.")
        
        # First, try custom archive path if provided
        if custom_archive_path and handle_local_archive(custom_archive_path, local_path):
            return True
        
        # Check for compressed tar files before downloading
        tar_path = get_local_zip_path(model_id)  # This returns .tar.gz path


        print(f"[LOADER] No local archive found. Starting download from MyData Tools cache server...")
        # ex: https://gcs-file-downloader-10805446439.us-central1.run.app/download/google-gemma-3-4b-it
        
        # Check for custom model download URL
        model_download_url = os.environ.get('MODEL_DOWNLOAD_URL')
        if model_download_url:
            print(f"[LOADER] Checking custom download URL: {model_download_url}")
            try:
                download_url = f"{model_download_url}/download/{model_id.replace('/', '-')}"
                # Use the .tar.gz path for the download
                tar_path = get_local_zip_path(model_id)
                print(f"[LOADER] Downloading from {download_url} to {tar_path}...")
            
                urllib.request.urlretrieve(download_url, tar_path)
            
                if handle_local_archive(tar_path, local_path):
                    print(f"[LOADER] Successfully downloaded and extracted model from custom URL.")
                    return True
                else:
                    print(f"[ERROR] Failed to extract downloaded archive from {download_url}")
            except Exception as e:
                print(f"[ERROR] Failed to download from custom URL: {e}")
                # Fall through to standard logic

        if len(tar_path) == 0:
            # last ditch effort to download model
            # No archive found or extraction failed, proceed with download
            if os.environ.get('HF_TOKEN') and os.environ.get('HF_TOKEN') != '':
                print(f"[LOADER] No local archive found. Starting download from Hugging Face...")
                try:
                    snapshot_download(
                        repo_id=model_id, 
                        local_dir=local_path, 
                    )
                    print("[LOADER] Model download complete.")
                except Exception as dl_error:
                    print(f"[ERROR] Error during hugging face model download for {model_id}: {dl_error}")
                    return False
        else:
            # Check out the tar_path and unzip the downloaded model

            alternative_paths = [
                tar_path,  # .tar.gz from get_local_zip_path
                tar_path.replace('.tar.gz', '.tgz'),  # .tgz variant
                tar_path.replace('.tar.gz', '.tar')   # uncompressed .tar
            ]

            if len(alternative_paths) == 0:
                raise Exception("Unable to find model to use");

            # Try each archive format
            for archive_path in alternative_paths:
                if handle_local_archive(archive_path, local_path):
                    return True


    else:
        print(f"[LOADER] Local model found at {local_path}. Skipping download.")
        return True
        
    return False

