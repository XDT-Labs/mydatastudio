"""
Main FastAPI application — OpenAI-compatible local LLM server.

Endpoints:
  GET  /                          Health check
  POST /v1/chat/completions       OpenAI-compatible chat (auto-loads model)
  POST /v1/embeddings             OpenAI-compatible text embeddings
  POST /util/download-model       Download a GGUF model from Hugging Face
  POST /util/embedding            Multimodal embeddings (text or image)
  POST /util/thumbnail            Generate image thumbnails (incl. RAW formats)
  POST /util/import/pst           Stream-parse an Outlook PST file
"""
import os
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE, DEFAULT_MODEL_ALIAS, MODEL_REGISTRY, API_TITLE, API_DESCRIPTION
from .utils import get_local_path, find_local_model
from . import routes


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

# OpenAI-compatible
app.post("/v1/chat/completions", summary="OpenAI-compatible chat completion")(routes.generate_chat_completion)
app.post("/v1/embeddings", summary="OpenAI-compatible text embeddings")(routes.generate_embedding_v1)

# Util
app.post("/util/download-model", summary="Download a GGUF model from Hugging Face")(routes.download_model)
app.post("/util/embedding", summary="Multimodal embeddings (text or image)")(routes.generate_embedding)
app.post("/util/thumbnail", summary="Generate image thumbnail (incl. RAW formats)")(routes.generate_thumbnail)
app.post("/util/import/pst", summary="Stream-parse an Outlook PST file")(routes.import_pst)


def main() -> None:
    os.makedirs("models", exist_ok=True)

    # Auto-load default model at startup if present locally.
    # Resolve through registry so the stored ID matches what the client sends.
    default_entry = MODEL_REGISTRY.get(DEFAULT_MODEL_ALIAS, {})
    startup_model_name = default_entry.get("model_name", DEFAULT_LOCAL_MODEL)
    startup_model_file = default_entry.get("model_file", DEFAULT_GGUF_FILE)

    local_path = get_local_path(startup_model_name)
    model_path = find_local_model(startup_model_file, local_path)
    if model_path:
        try:
            print(f"[STARTUP] Loading '{DEFAULT_MODEL_ALIAS}' ({startup_model_name})...")
            from .model_manager import load_local_model
            from .state import set_llm_instance, set_current_model_id
            llm = load_local_model(model_name=startup_model_name, model_path=model_path)
            set_llm_instance(llm)
            set_current_model_id(DEFAULT_MODEL_ALIAS)  # store alias, not HF repo ID
            print(f"[STARTUP] Model '{DEFAULT_MODEL_ALIAS}' loaded successfully.")
        except Exception as e:
            print(f"[STARTUP] Failed to load model: {e}")
    else:
        print(f"[STARTUP] '{startup_model_file}' not found locally. Skipping auto-load.")

    import uvicorn
    port = int(os.environ.get("AICHAT_PORT", 0))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="info", reload=False)


if __name__ == "__main__":
    import multiprocessing
    try:
        multiprocessing.set_start_method('spawn')
    except RuntimeError:
        pass
    multiprocessing.freeze_support()
    main()
