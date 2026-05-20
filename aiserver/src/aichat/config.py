"""
Configuration settings for the Gemma Local Chat API.

This module contains all configuration constants and settings used throughout
the application. Centralizing configuration makes it easier to maintain and
modify application behavior.
"""

# Default model configuration
DEFAULT_LOCAL_MODEL = "bartowski/gemma-3-4b-it-GGUF"  # Default model repository to load at startup
DEFAULT_GGUF_FILE = "gemma-3-4b-it-Q4_K_M.gguf"       # Default GGUF file to utilize

# Model loading configuration
MAX_NEW_TOKENS = 512        # Maximum tokens to generate in response
TEMPERATURE = 0.7           # Sampling temperature for text generation
DO_SAMPLE = True           # Whether to use sampling vs greedy decoding

# File paths
MODELS_BASE_DIR = "./models"  # Base directory for storing model files

# FastAPI configuration
API_TITLE = "Gemma 2 Local Chat Endpoint with GGUF Dynamic Loading"
API_DESCRIPTION = "API to dynamically download, load, and chat with local GGUF format Hugging Face models."