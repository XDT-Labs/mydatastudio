"""
Configuration settings for the local LLM server.
Model details live in the Flutter SQLite DB (aichat_models table),
resolved at runtime via model_registry.py.
"""

DEFAULT_MODEL_ALIAS = "gemma4:12b"

# ── Fallback defaults (used as Pydantic field defaults; not a model registry) ─
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
