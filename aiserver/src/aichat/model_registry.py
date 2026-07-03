"""
Resolves model aliases by querying the Flutter SQLite database (mydata.db).
The DB path is read from config.json, which Flutter writes on every startup.
"""
import json
import os
import sqlite3
from typing import Optional

_db_path_cache: Optional[str] = None


def _resolve_support_dir() -> Optional[str]:
    """Return the Application Support directory, trying env vars then platform fallback."""
    # Set by Flutter's PythonManager when spawning the process
    support_dir = os.environ.get('APP_SUPPORT_DIR')
    if support_dir and os.path.isdir(support_dir):
        return support_dir

    # Dev fallback: derive from AICHAT_MODELS_DIR (<support>/aichat/models → up two)
    models_dir = os.environ.get('AICHAT_MODELS_DIR')
    if models_dir:
        candidate = os.path.realpath(os.path.join(models_dir, '..', '..'))
        if os.path.isdir(candidate):
            return candidate

    # Last resort: macOS platform path (covers running directly from IDE)
    home = os.path.expanduser('~')
    for bundle_id in ('com.xdtlabs.mydatastudio.dev', 'com.xdtlabs.mydatastudio'):
        # Standard path
        candidate = os.path.join(home, 'Library', 'Application Support', bundle_id)
        if os.path.isdir(candidate):
            return candidate

        # Sandboxed App paths (check both with and without bundle_id suffix)
        sandbox_base = os.path.join(home, 'Library', 'Containers', bundle_id, 'Data', 'Library', 'Application Support')
        for sandbox_cand in (os.path.join(sandbox_base, bundle_id), sandbox_base):
            if os.path.isdir(sandbox_cand):
                return sandbox_cand

    return None


_db_resolution_attempted = False


def _resolve_db_path() -> Optional[str]:
    global _db_path_cache, _db_resolution_attempted
    if _db_path_cache is not None:
        return _db_path_cache

    support_dir = _resolve_support_dir()
    if not support_dir:
        if not _db_resolution_attempted:
            print("[DB] Could not locate Application Support directory")
            _db_resolution_attempted = True
        return None

    config_path = os.path.join(support_dir, 'config.json')
    if not os.path.exists(config_path):
        if not _db_resolution_attempted:
            print(f"[DB] config.json not found at {config_path}")
            _db_resolution_attempted = True
        return None

    try:
        with open(config_path) as f:
            config = json.load(f)
        db_dir = config.get('database') or config.get('storage')
        if db_dir:
            _db_path_cache = os.path.join(db_dir, 'data', 'mydata.db')
    except Exception as e:
        print(f"[DB] Failed to read config.json: {e}")

    return _db_path_cache


def lookup(alias: str) -> Optional[dict]:
    """Return the aichat_models row for the given alias, or None if not found."""
    db_path = _resolve_db_path()
    if not db_path or not os.path.exists(db_path):
        return None

    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        con.row_factory = sqlite3.Row
        row = con.execute(
            'SELECT * FROM aichat_models WHERE alias = ? LIMIT 1', (alias,)
        ).fetchone()
        con.close()
        return dict(row) if row else None
    except Exception as e:
        print(f"[DB] lookup failed for alias '{alias}': {e}")
        return None
