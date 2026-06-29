"""
Configuration settings for the local LLM server.
"""

# ── Model registry ────────────────────────────────────────────────────────────
# Maps simple client-facing aliases (e.g. "gemma3:4b") to the HuggingFace
# repo ID and GGUF filename used for local storage and loading.
# Soon this will be pulled from the database; for now it is hardcoded here.

MODEL_REGISTRY: dict = {
    "gemma4:12b": {
        "model_name": "ggml-org/gemma-4-12B-it-GGUF",
        "model_file": "gemma-4-12B-it-Q4_K_M.gguf",
        "model_file_mmproj": "mmproj-gemma-4-12B-it-Q8_0.gguf",
    },
}

DEFAULT_MODEL_ALIAS = "gemma4:12b"

# ── Fallback values (used when a model is not in the registry) ────────────────
DEFAULT_LOCAL_MODEL = "ggml-org/gemma-4-12B-it-GGUF"
DEFAULT_GGUF_FILE = "gemma-4-12B-it-Q4_K_M.gguf"

# ── Model loading ─────────────────────────────────────────────────────────────
MAX_NEW_TOKENS = 512
TEMPERATURE = 0.7
DO_SAMPLE = True

# ── File paths ────────────────────────────────────────────────────────────────
MODELS_BASE_DIR = "./models"

# ── FastAPI ───────────────────────────────────────────────────────────────────
API_TITLE = "MyDataStudio Local LLM Server"
API_DESCRIPTION = "OpenAI-compatible local LLM server using llama.cpp GGUF models."
