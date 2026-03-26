"""
Main FastAPI application for Gemma Local Chat API.

This is the entry point for the Gemma Local Chat API server. It sets up the FastAPI
application, configures startup/shutdown events, registers route handlers, and can
be run directly to start the server.

The application provides:
- Chat completions with dynamically loaded Gemma models
- Embedding generation for text and images  
- Model management with local caching and archive support
- Health monitoring and status endpoints

Usage:
    python main.py                          # Run with default settings
    uvicorn main:app --reload --port 8000   # Run with uvicorn (recommended)
"""
import os
from fastapi import FastAPI
from typing import Optional

from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE, API_TITLE, API_DESCRIPTION
from .models import ChatRequest, StartSessionRequest, EmbeddingRequest
from .utils import get_local_path, find_local_model
from . import routes


# Create FastAPI app with configuration
app = FastAPI(
    title=API_TITLE,
    description=API_DESCRIPTION,
    version="1.0.0",
    docs_url="/docs",  # Swagger UI at /docs
    redoc_url="/redoc"  # ReDoc UI at /redoc
)

# Register API route handlers
app.get("/", summary="Health Check")(routes.health_check)
app.post("/start-session", summary="Load a local GGUF model for chat")(routes.start_session)
app.post("/download-model", summary="Download a GGUF model from Hugging Face Hub")(routes.download_model)
app.post("/chat", summary="Generate a chat response using the currently loaded model")(routes.generate_chat_response)
app.post("/embedding", summary="Generate embeddings for text or image using Gemma-3-4B")(routes.generate_embedding)
app.post("/import/pst", summary="Import and parse an Outlook PST file")(routes.import_pst)
app.post("/thumbnail", summary="Generate a thumbnail for an image, including RAW formats")(routes.generate_thumbnail)



def main() -> None:
    """
    Main entry point for running the application.
    
    Starts the uvicorn server with default configuration suitable for
    development. For production deployment, use uvicorn directly with
    appropriate settings for your environment.
    
    Example:
        python main.py  # Production server
        
    For production:
        uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4
    """

    # make a local directory for models
    os.makedirs("models", exist_ok=True)

    # Initialize default model at startup
    print(f"[STARTUP] Initializing default model: {DEFAULT_LOCAL_MODEL}")
    local_path = get_local_path(DEFAULT_LOCAL_MODEL)
    
    # Locate the model file locally — never auto-download at startup
    model_path = find_local_model(DEFAULT_GGUF_FILE, local_path)
    
    if model_path:
        try:
            print(f"[STARTUP] Loading model {DEFAULT_LOCAL_MODEL}...")
            # Import here to avoid circular imports if any
            from .model_manager import load_local_model
            from .state import set_llm_instance, set_current_model_id
            
            llm = load_local_model(model_name=DEFAULT_LOCAL_MODEL, model_path=model_path)
            set_llm_instance(llm)
            set_current_model_id(DEFAULT_LOCAL_MODEL)
            print(f"[STARTUP] Model loaded successfully.")
        except Exception as e:
            print(f"[STARTUP] Failed to load model: {e}")
            # We continue to start the server so the client can at least connect,
            # but the model won't be loaded.
    else:
        print(f"[STARTUP] Model file '{DEFAULT_GGUF_FILE}' not found locally. Skipping auto-load.")
    
    # Run the server
    import uvicorn
    uvicorn.run(
        app, 
        host="0.0.0.0", 
        port=0,
        log_level="info",
        reload=False  # Set to True for development
    )


if __name__ == "__main__":
    import multiprocessing
    
    # Set the multiprocessing start method to "spawn" to prevent fork bombs on macOS
    # when loading large models with Transformers
    try:
        multiprocessing.set_start_method('spawn')
    except RuntimeError:
        pass # The start method has already been set
        
    multiprocessing.freeze_support()
    main()
