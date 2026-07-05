"""
Utility functions for file operations, path management, and archive handling.

This module provides helper functions for managing model files, including
path generation, archive extraction, and model downloading from Hugging Face Hub.
"""
import os
import tarfile
import urllib.request
from typing import Optional


def _resolve_models_base() -> str:
    """
    Resolve the absolute base directory for model storage using this priority chain:

    1. AICHAT_MODELS_DIR env var — set by Flutter's PythonManager when spawning
       the subprocess. Always wins when present.
    2. PyInstaller frozen binary — use the directory containing sys.executable.
       The binary lives in Application Support/aichat/, so models land beside it.
    3. macOS dev fallback — scan ~/Library/Application Support for the known bundle
       IDs and use the first one whose aichat/ sub-directory already exists.
    4. Last resort — ./models/ relative to CWD (original behaviour).
    """
    import sys

    if env_dir := os.environ.get('AICHAT_MODELS_DIR'):
        return env_dir

    if getattr(sys, 'frozen', False):
        return os.path.join(os.path.dirname(os.path.abspath(sys.executable)), 'models')

    if sys.platform == 'darwin':
        home = os.path.expanduser('~')
        app_support = os.path.join(home, 'Library', 'Application Support')
        for bundle_id in ('com.xdtlabs.mydatastudio.dev', 'com.xdtlabs.mydatastudio'):
            bundle_dir = os.path.join(app_support, bundle_id)
            if os.path.isdir(bundle_dir):
                return os.path.join(bundle_dir, 'aichat', 'models')

            # Sandboxed App paths (check both with and without bundle_id suffix)
            sandbox_base = os.path.join(home, 'Library', 'Containers', bundle_id, 'Data', 'Library', 'Application Support')
            for sandbox_cand in (os.path.join(sandbox_base, bundle_id), sandbox_base):
                sandbox_dir = os.path.join(sandbox_cand, 'aichat', 'models')
                if os.path.isdir(os.path.join(sandbox_cand, 'aichat')):
                    return sandbox_dir

    return os.path.join(os.getcwd(), 'models')


def get_local_path(model_id: str) -> str:
    """
    Return the absolute directory path for storing a specific model's files.

    Args:
        model_id (str): Hugging Face model identifier (e.g., 'google/gemma-2-9b-it')

    Returns:
        str: Absolute directory path for this model.
    """
    if model_id is None:
        model_id = "unknown"
    safe_model_name = model_id.replace('/', '-').replace('..', '')
    return os.path.join(_resolve_models_base(), f"{safe_model_name}-local")


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
    if model_id is None:
        model_id = "unknown"
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
        
        # Extract the archive safely (auto-detects compression format)
        with tarfile.open(archive_path, 'r:*') as tar:
            # Validate all members before extraction to prevent path traversal
            for member in tar.getmembers():
                member_path = os.path.normpath(os.path.join(target_dir, member.name))
                if not member_path.startswith(os.path.realpath(target_dir)):
                    raise ValueError(f"Tar member '{member.name}' would escape target directory")
                if member.name.startswith('/') or '..' in member.name.split('/'):
                    raise ValueError(f"Tar member '{member.name}' contains unsafe path components")
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

    # 3. Flat models/ root (manually placed or pre-downloaded files)
    models_root = os.path.normpath(os.path.join(os.getcwd(), 'models'))
    print(f"[LOADER] Checking models root: {models_root}")
    found = _fuzzy_find(models_root, filename)
    if found:
        print(f"[LOADER] Found model in models root: {found}")
        return found

    # 4. Explicit local_path (models downloaded via /util/download-model)
    print(f"[LOADER] Checking local path: {local_path}")
    found = _fuzzy_find(local_path, filename)
    if found:
        print(f"[LOADER] Found model at local path: {found}")
        return found

    return None


def download_gguf_model(model_id: str, filename: str, local_path: str, hf_token: Optional[str] = None) -> str:
    """
    Download a GGUF model from Hugging Face Hub into local_path.

    This should only be called explicitly (e.g., from the /download-model endpoint),
    never automatically at startup.

    Args:
        model_id (str): Hugging Face model repository identifier.
        filename (str): The specific GGUF filename to download.
        local_path (str): Target directory for the downloaded file.
        hf_token (str | None): Optional HuggingFace API token for gated models.

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
        local_dir=local_path,
        token=hf_token or None,
    )
    print(f"[LOADER] Download complete: {downloaded_path}")
    return downloaded_path


def stream_download_gguf(model_id: str, filename: str, local_path: str, hf_token: Optional[str] = None):
    """
    Generator that streams a GGUF file download from HuggingFace and yields
    SSE-formatted progress events ('data: <json>\\n\\n').

    Events:
        {"status": "downloading", "progress": 0.0-1.0, "downloaded_mb": float, "total_mb": float}
        {"status": "complete",    "progress": 1.0, "model_path": str}
        {"status": "error",       "message": str}
    """
    import json
    import requests as req_lib
    from huggingface_hub import hf_hub_url

    os.makedirs(local_path, exist_ok=True)
    dest_path = os.path.join(local_path, os.path.basename(filename))

    req_headers = {'User-Agent': 'mydatastudio/1.0'}
    if hf_token:
        req_headers['Authorization'] = f'Bearer {hf_token}'

    try:
        url = hf_hub_url(repo_id=model_id, filename=filename)

        head = req_lib.head(url, headers=req_headers, allow_redirects=True, timeout=30)
        total_bytes = int(head.headers.get('content-length', 0))
        total_mb = round(total_bytes / (1024 * 1024), 1)

        yield f'data: {json.dumps({"status": "downloading", "progress": 0.0, "downloaded_mb": 0.0, "total_mb": total_mb})}\n\n'

        downloaded = 0
        last_reported = -1.0

        with req_lib.get(url, headers=req_headers, stream=True, timeout=60) as r:
            r.raise_for_status()
            with open(dest_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=524288):  # 512 KB
                    f.write(chunk)
                    downloaded += len(chunk)
                    progress = downloaded / total_bytes if total_bytes > 0 else 0.0
                    # Emit at most one event per 1% progress
                    if progress - last_reported >= 0.01 or progress >= 1.0:
                        downloaded_mb = round(downloaded / (1024 * 1024), 1)
                        yield f'data: {json.dumps({"status": "downloading", "progress": round(progress, 4), "downloaded_mb": downloaded_mb, "total_mb": total_mb})}\n\n'
                        last_reported = progress

        print(f"[LOADER] Stream download complete: {dest_path}")
        yield f'data: {json.dumps({"status": "complete", "progress": 1.0, "model_path": dest_path})}\n\n'

    except Exception as e:
        print(f"[ERROR] Stream download failed for {model_id}/{filename}: {e}")
        yield f'data: {json.dumps({"status": "error", "message": str(e)})}\n\n'


def _safe_repo_path(local_path: str, filename: str) -> str:
    """
    Resolve `filename` (as returned by HfApi.list_repo_files) against
    `local_path`, raising ValueError if it would escape that directory.

    `model_id` — and therefore which repo's file listing we trust — is
    caller-controlled via the download-model request, so a malicious or
    compromised repo could otherwise return a filename containing '..'
    segments to write outside the intended models directory.
    """
    if os.path.isabs(filename) or '..' in filename.replace('\\', '/').split('/'):
        raise ValueError(f"Unsafe path in repo listing: {filename!r}")

    base = os.path.realpath(local_path)
    dest = os.path.realpath(os.path.join(base, filename))
    if dest != base and not dest.startswith(base + os.sep):
        raise ValueError(f"Unsafe path in repo listing: {filename!r}")
    return dest


def stream_download_snapshot(model_id: str, local_path: str, hf_token: Optional[str] = None):
    """
    Generator that streams an entire HuggingFace repo snapshot (all files) into
    `local_path`, yielding SSE-formatted aggregate progress events.

    Used for multi-file Transformers models (e.g. Qwen3-VL-Embedding-2B) that
    can't be downloaded as a single GGUF file via stream_download_gguf(). Files
    already present locally (matching a prior partial/complete download) are
    skipped, so this is safe to call on every startup.

    Events:
        {"status": "downloading", "progress": 0.0-1.0, "downloaded_mb": float, "total_mb": float, "current_file": str}
        {"status": "complete",    "progress": 1.0, "model_path": str}
        {"status": "error",       "message": str}
    """
    import json
    import requests as req_lib
    from huggingface_hub import HfApi, hf_hub_url
    from huggingface_hub.hf_api import RepoFile

    req_headers = {'User-Agent': 'mydatastudio/1.0'}
    if hf_token:
        req_headers['Authorization'] = f'Bearer {hf_token}'

    try:
        os.makedirs(local_path, exist_ok=True)

        api = HfApi()
        skip = {'.gitattributes', 'README.md'}
        # recursive=True yields both RepoFile and RepoFolder entries; only
        # files carry a `size`, so filter to RepoFile before reading it.
        repo_files = [f for f in api.list_repo_tree(model_id, recursive=True, token=hf_token or None)
                      if isinstance(f, RepoFile) and f.path not in skip]
        all_files = [f.path for f in repo_files]
        sizes = {f.path: f.size for f in repo_files}

        # Validate every filename up front (raises on path traversal attempts)
        # before touching disk or the network.
        dest_paths = {f: _safe_repo_path(local_path, f) for f in all_files}

        # Only download files that aren't already on disk.
        pending = [f for f in all_files if not os.path.exists(dest_paths[f])]

        if not pending:
            yield f'data: {json.dumps({"status": "complete", "progress": 1.0, "model_path": local_path})}\n\n'
            return

        sizes = {f: sizes[f] for f in pending}

        total_bytes = sum(sizes.values())
        total_mb = round(total_bytes / (1024 * 1024), 1)
        downloaded_bytes = 0
        last_reported = -1.0

        yield f'data: {json.dumps({"status": "downloading", "progress": 0.0, "downloaded_mb": 0.0, "total_mb": total_mb, "current_file": pending[0]})}\n\n'

        for f in pending:
            dest_path = dest_paths[f]
            os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            url = hf_hub_url(repo_id=model_id, filename=f)

            with req_lib.get(url, headers=req_headers, stream=True, timeout=60) as r:
                r.raise_for_status()
                with open(dest_path, 'wb') as out:
                    for chunk in r.iter_content(chunk_size=524288):  # 512 KB
                        out.write(chunk)
                        downloaded_bytes += len(chunk)
                        progress = downloaded_bytes / total_bytes if total_bytes > 0 else 0.0
                        if progress - last_reported >= 0.01 or progress >= 1.0:
                            downloaded_mb = round(downloaded_bytes / (1024 * 1024), 1)
                            yield f'data: {json.dumps({"status": "downloading", "progress": round(progress, 4), "downloaded_mb": downloaded_mb, "total_mb": total_mb, "current_file": f})}\n\n'
                            last_reported = progress

        print(f"[LOADER] Snapshot download complete: {local_path}")
        yield f'data: {json.dumps({"status": "complete", "progress": 1.0, "model_path": local_path})}\n\n'

    except Exception as e:
        print(f"[ERROR] Snapshot download failed for {model_id}: {e}")
        yield f'data: {json.dumps({"status": "error", "message": str(e)})}\n\n'


def is_snapshot_downloaded(model_id: str, local_path: str) -> bool:
    """
    Cheap, local-only check for whether a full repo snapshot (see
    stream_download_snapshot) has already been downloaded. Does not hit the
    network — treats a non-empty local_path as "downloaded" since
    stream_download_snapshot only ever writes real repo files there.
    """
    return os.path.isdir(local_path) and any(
        not entry.name.startswith('.') for entry in os.scandir(local_path)
    )


def download_gguf_model_if_needed(model_id: str, filename: str, local_path: str) -> str:
    """
    DEPRECATED: Use find_local_model() + download_gguf_model() separately.

    Kept for backward compatibility. Finds an existing model or downloads it.
    """
    found = find_local_model(filename, local_path)
    if found:
        return found
    return download_gguf_model(model_id, filename, local_path)
