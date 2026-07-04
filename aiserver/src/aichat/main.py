"""
Main FastAPI application — OpenAI-compatible local LLM server.

Endpoints:
  GET  /                          Health check
  GET  /skills                    List built-in skills for client autocomplete
  POST /v1/chat/completions       OpenAI-compatible chat (auto-loads model)
  POST /v1/embeddings             OpenAI-compatible text embeddings
  POST /util/download-model       Download a GGUF file or full repo snapshot from Hugging Face
  POST /util/model-status         Check (local disk only) whether a model is already downloaded
  POST /util/embedding            Multimodal embeddings (text or image)
  POST /util/thumbnail            Generate image thumbnails (incl. RAW formats)
  POST /util/import/pst           Stream-parse an Outlook PST file
"""
import json
import logging
import os
import sys
from datetime import datetime
from typing import Optional

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE, DEFAULT_MODEL_ALIAS, API_TITLE, API_DESCRIPTION
from .utils import get_local_path, find_local_model, _resolve_models_base
from . import routes, model_registry

logger = logging.getLogger(__name__)


def _get_log_dir() -> Optional[str]:
    """Resolve <storage>/logs from config.json, falling back to <app-support>/logs."""
    support_dir = os.environ.get('APP_SUPPORT_DIR')
    if not support_dir or not os.path.isdir(support_dir):
        home = os.path.expanduser('~')
        for bundle_id in ('com.xdtlabs.mydatastudio.dev', 'com.xdtlabs.mydatastudio'):
            # Standard path
            candidate = os.path.join(home, 'Library', 'Application Support', bundle_id)
            if os.path.isdir(candidate):
                support_dir = candidate
                break

            # Sandboxed App paths (check both with and without bundle_id suffix)
            sandbox_base = os.path.join(home, 'Library', 'Containers', bundle_id, 'Data', 'Library', 'Application Support')
            found_sandbox = False
            for sandbox_cand in (os.path.join(sandbox_base, bundle_id), sandbox_base):
                if os.path.isdir(sandbox_cand):
                    support_dir = sandbox_cand
                    found_sandbox = True
                    break
            if found_sandbox:
                break

    if not support_dir:
        return None

    config_path = os.path.join(support_dir, 'config.json')
    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
            storage = config.get('storage') or config.get('database')
            if storage:
                return os.path.join(storage, 'logs')
        except Exception:
            pass

    return os.path.join(support_dir, 'logs')


def setup_logging(log_level: str = 'info') -> None:
    """Configure root logger with console + timestamped file handler."""
    level = getattr(logging, log_level.upper(), logging.INFO)
    fmt = logging.Formatter(
        '%(asctime)s | %(levelname)-8s | %(name)s | %(message)s',
        datefmt='%Y-%m-%dT%H:%M:%S',
    )

    root = logging.getLogger()
    root.setLevel(level)

    # Console handler (stderr — Flutter reads both stdout and stderr)
    ch = logging.StreamHandler(sys.stderr)
    ch.setLevel(level)
    ch.setFormatter(fmt)
    root.addHandler(ch)

    # File handler — new timestamped file each startup
    log_dir = _get_log_dir()
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
        timestamp = datetime.now().strftime('%Y-%m-%d_%H-%M-%S')
        log_file = os.path.join(log_dir, f'aiserver_{timestamp}.log')
        fh = logging.FileHandler(log_file, encoding='utf-8')
        fh.setLevel(level)
        fh.setFormatter(fmt)
        root.addHandler(fh)
        print(f"[STARTUP] Logging to: {log_file}")


app = FastAPI(
    title=API_TITLE,
    description=API_DESCRIPTION,
    version="2.0.0",
    docs_url=None,
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost", "http://127.0.0.1"],
    allow_methods=["POST", "GET"],
    allow_headers=["*"],
)

# Health
app.get("/")(routes.health_check)

# Skills registry
app.get("/skills", summary="List built-in skills")(routes.get_skills)

# OpenAI-compatible
app.post("/v1/chat/completions", summary="OpenAI-compatible chat completion")(routes.generate_chat_completion)
app.post("/v1/chat/stop", summary="Stop the active streaming generation")(routes.stop_generation)
app.post("/v1/embeddings", summary="OpenAI-compatible text embeddings")(routes.generate_embedding_v1)

# Util
app.post("/util/download-model", summary="Download a GGUF model or full repo snapshot from Hugging Face")(routes.download_model)
app.post("/util/model-status", summary="Check whether a model is already downloaded (local disk only)")(routes.check_model_status)
app.post("/util/delete-model", summary="Delete a downloaded GGUF model file")(routes.delete_model)
app.post("/util/embedding", summary="Multimodal embeddings (text or image)")(routes.generate_embedding)
app.post("/util/thumbnail", summary="Generate image thumbnail (incl. RAW formats)")(routes.generate_thumbnail)
app.post("/util/import/pst", summary="Stream-parse an Outlook PST file")(routes.import_pst)


def main() -> None:
    # Debug builds (script) default to debug; frozen binaries default to info.
    _default_level = 'info' if getattr(sys, 'frozen', False) else 'debug'
    log_level = os.environ.get('AISERVER_LOG_LEVEL', _default_level)
    setup_logging(log_level)

    models_dir = _resolve_models_base()
    os.makedirs(models_dir, exist_ok=True)
    logger.info(f"[STARTUP] Models directory: {models_dir}")

    # Auto-load default model at startup if present locally.
    db_row = model_registry.lookup(DEFAULT_MODEL_ALIAS)
    startup_model_name = (db_row or {}).get("hf_repo") or DEFAULT_LOCAL_MODEL
    startup_model_file = (db_row or {}).get("file") or DEFAULT_GGUF_FILE
    startup_mmproj_file = (db_row or {}).get("mmproj")

    local_path = get_local_path(startup_model_name)
    model_path = find_local_model(startup_model_file, local_path)
    if model_path:
        try:
            mmproj_path = find_local_model(startup_mmproj_file, local_path) if startup_mmproj_file else None
            if startup_mmproj_file and not mmproj_path:
                logger.warning(f"[STARTUP] mmproj '{startup_mmproj_file}' not found — loading text-only.")
            logger.info(f"[STARTUP] Loading '{DEFAULT_MODEL_ALIAS}' ({startup_model_name})...")
            from .model_manager import load_local_model
            from .state import set_llm_instance, set_current_model_id
            llm = load_local_model(
                model_name=startup_model_name,
                model_path=model_path,
                clip_model_path=mmproj_path,
            )
            set_llm_instance(llm)
            set_current_model_id(DEFAULT_MODEL_ALIAS)  # store alias, not HF repo ID
            logger.info(f"[STARTUP] Model '{DEFAULT_MODEL_ALIAS}' loaded successfully.")
        except Exception as e:
            logger.error(f"[STARTUP] Failed to load model: {e}")
    else:
        logger.info(f"[STARTUP] '{startup_model_file}' not found locally. Skipping auto-load.")

    import uvicorn
    port = int(os.environ.get("AICHAT_PORT", 0))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level=log_level, reload=False)


if __name__ == "__main__":
    import multiprocessing
    try:
        multiprocessing.set_start_method('spawn')
    except RuntimeError:
        pass
    multiprocessing.freeze_support()
    main()
