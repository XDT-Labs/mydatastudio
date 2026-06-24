"""
API route handlers for the Gemma Local Chat API.

This module contains all the FastAPI route handler functions that implement
the business logic for the API endpoints. Each function corresponds to a
specific API endpoint and handles request processing, validation, and response generation.
"""
from typing import Optional, Dict, Any, Generator
from fastapi import HTTPException
from fastapi.responses import StreamingResponse
import os
import json
from PIL import Image

from .models import ChatRequest, StartSessionRequest, EmbeddingRequest, PstImportRequest, ThumbnailRequest
from .pst_parser import PstParser
from .model_manager import (
    load_local_model,
    load_embedding_model,
    generate_embedding as gen_emb_fn,
    load_gemini_model
)
from .utils import get_local_path, find_local_model, download_gguf_model
from .state import (
    get_llm_instance, set_llm_instance,
    get_current_model_id, set_current_model_id,
    get_embedding_model, set_embedding_model,
    get_embedding_model_id, set_embedding_model_id,
    get_locks
)

def generate_thumbnail(request: ThumbnailRequest) -> Dict[str, Any]:
    """
    Generate a thumbnail for an image file, including RAW formats like NEF.
    
    Args:
        request (ThumbnailRequest): File path and target dimensions
        
    Returns:
        Dict[str, Any]: Base64 encoded thumbnail image (JPEG)
    """
    if not os.path.exists(request.file_path):
        raise HTTPException(status_code=404, detail="File not found")

    try:
        ext = os.path.splitext(request.file_path)[1].lower()
        
        # Handle RAW formats with rawpy
        if ext in ['.nef', '.cr2', '.arw', '.dng', '.orf', '.sr2']:
            import rawpy
            with rawpy.imread(request.file_path) as raw:
                # postprocess decodes the raw image into an RGB array
                rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, bright=1.0)
                img = Image.fromarray(rgb)
        else:
            # Handle standard formats with Pillow
            img = Image.open(request.file_path)

        # Generate thumbnail
        img.thumbnail((request.width, request.height))
        
        # Save to buffer
        import io
        import base64
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        base64_thumb = base64.b64encode(buf.getvalue()).decode('utf-8')
        
        return {
            "thumbnail": base64_thumb,
            "width": img.width,
            "height": img.height,
            "format": "JPEG"
        }
    except Exception as e:
        print(f"[ERROR] Thumbnail generation failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to generate thumbnail: {e}")


async def health_check() -> Dict[str, Any]:
    """
    Health check endpoint that returns the current status of the API and loaded models.
    
    Provides information about:
    - API service status
    - Currently loaded chat model
    - Currently loaded embedding model  
    - Whether models are currently being loaded
    
    Returns:
        Dict[str, Any]: Status information including model states and loading status
        
    Example Response:
        {
            "status": "online",
            "current_chat_model": "google/gemma-3-4b-it",
            "chat_model_loaded": true,
            "current_embedding_model": "google/gemma-3-4b-it", 
            "embedding_model_loaded": true,
            "is_loading": false
        }
    """
    model_lock, embedding_lock = get_locks()
    embedding_model, _ = get_embedding_model()
    
    return {
        "status": "online",
        "current_chat_model": get_current_model_id() if get_llm_instance() else "None (Session not started)",
        "chat_model_loaded": get_llm_instance() is not None,
        "current_embedding_model": get_embedding_model_id() if embedding_model else "None",
        "embedding_model_loaded": embedding_model is not None,
        "is_loading": model_lock.locked() or embedding_lock.locked()
    }


async def start_session(request: StartSessionRequest) -> Dict[str, Any]:
    """
    Start a new model session by downloading and loading a specified model.
    
    This endpoint must be called successfully before using the chat endpoint.
    It handles model downloading from HuggingFace Hub or local archives,
    loads the model into memory, and makes it available for chat operations.
    
    The function implements several optimizations:
    - Checks if the requested model is already loaded
    - Uses async locks to prevent concurrent loading
    - Supports both HuggingFace Hub downloads and local archive files
    - Provides detailed error messages for troubleshooting
    
    Args:
        request (StartSessionRequest): Request containing model_name and optional local_path
        
    Returns:
        Dict[str, Any]: Success response with model information and status
        
    Raises:
        HTTPException: If model download or loading fails
        
    Example:
        >>> # Load from HuggingFace Hub
        >>> await start_session(StartSessionRequest(model_name="google/gemma-3-4b-it"))
        
        >>> # Load from local archive
        >>> await start_session(StartSessionRequest(
        ...     model_name="custom-model",
        ...     local_path="./models/custom-model.tar.gz"
        ... ))
    """
    model_lock, _ = get_locks()
    model_id = request.model_name
    filename = request.filename
    local_path = get_local_path(model_id)

    print(f"[STARTUP] start session with model {model_id}")

    # 1. Check if the requested model is already loaded
    if get_current_model_id() == model_id:
        return {"status": "success", "message": f"Session already active with model: {model_id}", "model": model_id}

    # Use a lock to prevent multiple model loading attempts concurrently
    async with model_lock:
        # Re-check inside the lock in case another thread just finished loading it
        if get_current_model_id() == model_id:
            return {"status": "success", "message": f"Session already active with model: {model_id}", "model": model_id}
        
        # 2. Locate the model file — no automatic download
        if model_id != "gemini":
            model_path = find_local_model(request.filename, get_local_path(model_id))
            if model_path is None:
                raise HTTPException(
                    status_code=404,
                    detail=f"Model file '{request.filename}' not found locally. "
                           f"Use the /download-model endpoint to download it first."
                )
        
        # 3. Load the model
        try:
            import gc
            
            # Clear previous model instance before loading new one explicitly
            old_llm = get_llm_instance()
            if old_llm is not None:
                print("[LOADER] Trying to free previous model from memory...")
                set_llm_instance(None)
                del old_llm
                # Force garbage collection to ensure C++ underlying objects are freed
                gc.collect()
            
            set_current_model_id(None)

            if model_id == "gemini":
                if request.system_instruction:
                    new_llm = load_gemini_model(system_instruction=request.system_instruction)
                else:
                    new_llm = load_gemini_model()
            else:
                new_llm = load_local_model(model_name=model_id, model_path=model_path)
            
            set_llm_instance(new_llm)
            set_current_model_id(model_id)
            
            print(f"[LOADER] Model {model_id} loaded and set as active session.")
            
            return {
                "status": "success", 
                "message": f"Model '{model_id}' successfully loaded and session started.",
                "model": get_current_model_id(),
                "local_path": local_path
            }

        except Exception as e:
            print(f"[ERROR] Failed to load model {model_id}: {e}")
            set_llm_instance(None)
            set_current_model_id(None)
            raise HTTPException(
                status_code=500,
                detail="Failed to load model into memory. Check console for details."
            )


async def generate_chat_response(request: ChatRequest) -> Dict[str, Any]:
    """
    Generate a chat response using the currently loaded language model.
    
    Sends a user prompt to the loaded model and returns the AI-generated response.
    The model must be loaded first using the start_session endpoint. This function
    formats the prompt according to Gemma model conventions and handles response parsing.
    
    The function automatically:
    - Formats prompts with Gemma-specific tokens (<start_of_turn>, <end_of_turn>)
    - Includes optional system instructions
    - Strips input prompt from model output
    - Handles response formatting and cleanup
    - Optionally wraps response in GenUI JSON format
    
    Args:
        request (ChatRequest): Request containing the user prompt and optional system instruction
        
    Returns:
        Dict[str, Any]: Response containing the user prompt, AI response, and model used
        
    Raises:
        HTTPException: If no model is loaded (503) or if generation fails (500)
        
    Example:
        >>> response = await generate_chat_response(ChatRequest(
        ...     prompt="Explain quantum computing in simple terms",
        ...     system_instruction="You are a helpful science teacher"
        ... ))
        >>> print(response["ai_response"])
    """
    llm_instance = get_llm_instance()
    
    if llm_instance is None:
        raise HTTPException(
            status_code=503,
            detail=f"No active model session. Please call the /start-session endpoint first, e.g., using model_name: 'google/gemma-3-4b-it'."
        )

    try:
        # Import GenUI helpers and ConversationManager
        from .genui_schema import GENUI_SYSTEM_PROMPT
        from .state import conversation_manager
        
        # Retrieve history for this session
        history_turns = await conversation_manager.get_history(request.session_id)
        history_text = "".join(history_turns)
        
        # Build system instruction
        system_inst = request.system_instruction or ""
        if request.use_genui:
            # Add GenUI instructions to system prompt
            system_inst = f"{system_inst}\n\n{GENUI_SYSTEM_PROMPT}" if system_inst else GENUI_SYSTEM_PROMPT
        
        # Construct the new turn
        new_turn = f"<start_of_turn>user\n"
        if system_inst and not history_text: # Only add system instruction to the very first turn
             new_turn += f"System Instruction: {system_inst}\n\n"
        new_turn += f"{request.prompt}<end_of_turn>\n<start_of_turn>model\n"

        # Combine history and new turn
        full_prompt = history_text + new_turn

        # The LangChain LlamaCpp wrapper takes a single string input
        response_text = llm_instance.invoke(full_prompt)
        ai_response = response_text.strip()

        return {
            "user_prompt": request.prompt,
            "ai_response": ai_response,
            "model_used": get_current_model_id(),
        }

    except Exception as e:
        print(f"[ERROR] An error occurred during model invocation: {e}")
        raise HTTPException(
            status_code=500,
            detail="Failed to generate response. Check server logs for details."
        )



async def generate_embedding(request: EmbeddingRequest) -> Dict[str, Any]:
    """
    Generate high-dimensional vector embeddings for text or image input.
    
    Creates dense vector representations of text or images using the Gemma-3-4B
    multimodal model. These embeddings can be used for similarity search, 
    clustering, classification, and other machine learning tasks.
    
    The function supports:
    - Text embeddings from string input
    - Image embeddings from base64-encoded image data
    - Automatic model loading if not already loaded
    - Thread-safe concurrent request handling
    
    Args:
        request (EmbeddingRequest): Request containing either text or image_base64 data
        
    Returns:
        Dict[str, Any]: Response containing the embedding vector, input info, and metadata
        
    Raises:
        HTTPException: If both or neither text/image provided (400), or if processing fails (500)
        
    Example:
        >>> # Text embedding
        >>> response = await generate_embedding(EmbeddingRequest(
        ...     text="The quick brown fox jumps over the lazy dog"
        ... ))
        >>> embedding = response["embedding"]  # List[float] of 1024+ dimensions
        
        >>> # Image embedding  
        >>> response = await generate_embedding(EmbeddingRequest(
        ...     image_base64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB..."
        ... ))
    """
    _, embedding_lock = get_locks()
    
    # Validate request
    if not request.text and not request.image_base64:
        raise HTTPException(
            status_code=400,
            detail="Either 'text' or 'image_base64' must be provided."
        )
    if request.text and request.image_base64:
        raise HTTPException(
            status_code=400,
            detail="Only one of 'text' or 'image_base64' can be provided, not both."
        )
    

    # Load embedding model if not already loaded
    async with embedding_lock:
        embedding_model, embedding_processor = get_embedding_model()
        if embedding_model is None or embedding_processor is None:
            try:
                model_id = request.model_name
                filename = request.filename
                print(f"[EMBEDDING] Loading {model_id}/{filename} for embeddings...")
                local_path = get_local_path(model_id)
                model, processor = load_embedding_model(model_id, filename, local_path)
                set_embedding_model(model, processor)
                set_embedding_model_id(model_id)
            except Exception as e:
                print(f"[ERROR] Failed to load embedding model: {e}")
                raise HTTPException(
                    status_code=500,
                    detail="Failed to load embedding model. Check server logs for details."
                )
    
    try:
        embedding_model, embedding_processor = get_embedding_model()
        
        # Use the universal generate_embedding function from model_manager
        try:
            print(f"[EMBEDDING] Generating embedding for input_type: {'text' if request.text else 'image'}")
            embedding = gen_emb_fn(
                model=embedding_model,
                processor=embedding_processor,
                text=request.text,
                image_base64=request.image_base64
            )
            if request.text and request.image_base64:
                input_type = "multimodal"
            elif request.text:
                input_type = "text"
            else:
                input_type = "image"
            input_content = request.text if request.text else f"base64_image({len(request.image_base64)})"
            
            print(f"[EMBEDDING] Success! Generated embedding with dimension: {len(embedding)}")
        except ValueError as ve:
             print(f"[EMBEDDING] [ERROR] Validation error: {ve}")
             raise HTTPException(status_code=400, detail=str(ve))
            
        return {
            "embedding": embedding,
            "input_type": input_type,
            "input_content": input_content,
            "model_used": get_embedding_model_id(),
            "embedding_dimension": len(embedding)
        }
    
    except HTTPException:
        raise
    except ValueError as ve:
        print(f"[EMBEDDING] [ERROR] Value error: {ve}")
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        print(f"[EMBEDDING] [ERROR] Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(
            status_code=500,
            detail="Failed to generate embedding. Check server logs for details."
        )


async def download_model(request: StartSessionRequest) -> Dict[str, Any]:
    """
    Download a GGUF model from Hugging Face Hub.

    This endpoint handles model downloads explicitly — start_session will never
    trigger a download automatically. Call this from the settings panel when a
    user wants to add a new model.

    Args:
        request (StartSessionRequest): Request containing model_name and filename

    Returns:
        Dict[str, Any]: Success response with the local path to the downloaded file

    Raises:
        HTTPException: If the download fails
    """
    model_id = request.model_name
    filename = request.filename
    local_path = get_local_path(model_id)

    print(f"[DOWNLOAD] Request to download {model_id}/{filename}")

    # Check if already present before downloading
    existing = find_local_model(filename, local_path)
    if existing:
        return {
            "status": "success",
            "message": f"Model '{filename}' already exists locally.",
            "model_path": existing
        }

    try:
        downloaded_path = download_gguf_model(model_id, filename, local_path)
        return {
            "status": "success",
            "message": f"Model '{filename}' downloaded successfully.",
            "model_path": downloaded_path
        }
    except Exception as e:
        print(f"[ERROR] Download failed for {model_id}/{filename}: {e}")
        raise HTTPException(
            status_code=500,
            detail="Failed to download model. Check server logs for details."
        )


async def import_pst(request: PstImportRequest):
    """
    Import and parse an Outlook PST file.
    
    Streams JSON objects representing folders, emails, and attachments found in the PST.
    Attachments are extracted to the specified output directory.
    """
    # Validate file path
    file_path = os.path.realpath(request.file_path)
    if not file_path.lower().endswith('.pst'):
        raise HTTPException(status_code=400, detail="file_path must point to a .pst file")
    if not os.path.isfile(file_path):
        raise HTTPException(status_code=400, detail="file_path does not exist")
    output_dir = os.path.realpath(request.output_dir)

    def event_stream() -> Generator[str, None, None]:
        parser = PstParser(file_path, output_dir)
        try:
            parser.open()
            for item in parser.walk():
                yield json.dumps(item) + "\n"
            parser.close()
        except Exception as e:
            yield json.dumps({"type": "error", "message": str(e)}) + "\n"

    return StreamingResponse(event_stream(), media_type="application/x-json-stream")

