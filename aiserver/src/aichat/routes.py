"""
API route handlers.
"""
import gc
import os
import json
import time
import uuid
from typing import Dict, Any, Generator

from fastapi import HTTPException
from fastapi.responses import StreamingResponse
from PIL import Image

from .models import (
    ChatCompletionRequest, EmbeddingV1Request,
    EmbeddingRequest, DownloadModelRequest, DeleteModelRequest, ThumbnailRequest, PstImportRequest,
)
from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE, MODEL_REGISTRY, DEFAULT_MODEL_ALIAS
from .pst_parser import PstParser
from .model_manager import (
    load_local_model,
    load_embedding_model,
    generate_embedding as gen_emb_fn,
    load_gemini_model,
)
from .utils import get_local_path, find_local_model, download_gguf_model, stream_download_gguf, _resolve_models_base
from .state import (
    get_llm_instance, set_llm_instance,
    get_current_model_id, set_current_model_id,
    get_embedding_model, set_embedding_model,
    get_embedding_model_id, set_embedding_model_id,
    get_locks,
)


def _resolve_model(alias: str) -> tuple:
    """Resolve a model alias (e.g. 'gemma3:4b') to (model_name, model_file).
    Falls back to treating the value as a raw HF repo ID if not in the registry."""
    if alias in MODEL_REGISTRY:
        entry = MODEL_REGISTRY[alias]
        return entry["model_name"], entry["model_file"]
    return alias or DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE


async def health_check() -> Dict[str, Any]:
    model_lock, embedding_lock = get_locks()
    embedding_model, _ = get_embedding_model()
    return {
        "status": "online",
        "current_chat_model": get_current_model_id() if get_llm_instance() else "None (no model loaded)",
        "chat_model_loaded": get_llm_instance() is not None,
        "current_embedding_model": get_embedding_model_id() if embedding_model else "None",
        "embedding_model_loaded": embedding_model is not None,
        "is_loading": model_lock.locked() or embedding_lock.locked(),
    }


async def generate_chat_completion(request: ChatCompletionRequest):
    """
    OpenAI-compatible chat completion. Auto-loads the requested model if it
    differs from the currently loaded one.
    """
    model_lock, _ = get_locks()
    target_alias = request.model or DEFAULT_MODEL_ALIAS

    # Load or switch model if needed (compare by alias)
    if get_llm_instance() is None or target_alias != get_current_model_id():
        async with model_lock:
            # Re-check inside the lock to avoid double-loading
            if get_llm_instance() is None or target_alias != get_current_model_id():
                mmproj_path = None
                chat_handler_name = None
                registry_entry = MODEL_REGISTRY.get(target_alias, {})

                # When the client sends an explicit file path, use it directly
                # instead of going through the registry lookup + file discovery.
                if request.model_path:
                    model_name = target_alias
                    models_dir = os.path.realpath(_resolve_models_base())
                    model_path = os.path.realpath(request.model_path)
                    _assert_within_models_dir(model_path, models_dir, "model_path")
                    if not model_path.endswith('.gguf'):
                        raise HTTPException(status_code=400, detail="model_path must point to a .gguf file")
                    if not os.path.exists(model_path):
                        raise HTTPException(
                            status_code=404,
                            detail=f"Model file not found at path: {model_path}"
                        )
                    # Validate and use client-provided mmproj if present
                    if request.mmproj_path:
                        mmproj_candidate = os.path.realpath(request.mmproj_path)
                        _assert_within_models_dir(mmproj_candidate, models_dir, "mmproj_path")
                        if not mmproj_candidate.endswith('.gguf'):
                            raise HTTPException(status_code=400, detail="mmproj_path must point to a .gguf file")
                        if os.path.exists(mmproj_candidate):
                            mmproj_path = mmproj_candidate
                        else:
                            print(f"[LOADER] mmproj not found at {mmproj_candidate} — text-only mode")
                    # Chat handler comes from the registry if this alias is known
                    chat_handler_name = registry_entry.get("chat_handler")
                else:
                    model_name, filename = _resolve_model(target_alias)

                    if model_name != "gemini":
                        local_path = get_local_path(model_name)
                        model_path = find_local_model(filename, local_path)
                        if model_path is None:
                            raise HTTPException(
                                status_code=404,
                                detail=f"Model '{target_alias}' ({filename}) not found locally. "
                                       f"Use /util/download-model to download it first."
                            )
                        # Look up optional vision projector and handler from registry
                        mmproj_filename = registry_entry.get("model_file_mmproj")
                        chat_handler_name = registry_entry.get("chat_handler")
                        if mmproj_filename:
                            mmproj_path = find_local_model(mmproj_filename, local_path)
                        if mmproj_filename and not mmproj_path:
                            print(f"[LOADER] mmproj '{mmproj_filename}' not found — running text-only mode")

                old_llm = get_llm_instance()
                if old_llm is not None:
                    print("[LOADER] Freeing previous model from memory...")
                    set_llm_instance(None)
                    del old_llm
                    gc.collect()
                set_current_model_id(None)

                try:
                    if model_name == "gemini":
                        new_llm = load_gemini_model()
                    else:
                        new_llm = load_local_model(
                            model_name=model_name,
                            model_path=model_path,
                            clip_model_path=mmproj_path,
                            chat_handler_name=chat_handler_name,
                        )
                    set_llm_instance(new_llm)
                    set_current_model_id(target_alias)  # store the alias, not the HF repo ID
                    print(f"[LOADER] Model '{target_alias}' loaded.")
                except Exception as e:
                    print(f"[ERROR] Failed to load model '{target_alias}': {e}")
                    set_llm_instance(None)
                    set_current_model_id(None)
                    raise HTTPException(status_code=500, detail="Failed to load model.")

    llm_instance = get_llm_instance()
    if llm_instance is None:
        raise HTTPException(
            status_code=503,
            detail="No model loaded. Use /util/download-model to download a model, then retry."
        )

    try:
        messages = [{"role": m.role, "content": m.content} for m in request.messages]

        # llama_cpp.Llama (local GGUF, text or vision)
        if hasattr(llm_instance, 'create_chat_completion'):
            kwargs: Dict[str, Any] = {"messages": messages}
            if request.temperature is not None:
                kwargs["temperature"] = request.temperature
            if request.max_tokens is not None:
                kwargs["max_tokens"] = request.max_tokens

            if request.stream:
                current_model = get_current_model_id()

                def _sse_stream() -> Generator[str, None, None]:
                    for chunk in llm_instance.create_chat_completion(
                        stream=True, **kwargs
                    ):
                        chunk["model"] = current_model
                        yield f"data: {json.dumps(chunk)}\n\n"
                    yield "data: [DONE]\n\n"

                return StreamingResponse(_sse_stream(), media_type="text/event-stream")

            result = llm_instance.create_chat_completion(**kwargs)
            result["model"] = get_current_model_id() or result.get("model", "unknown")
            return result

        # Gemini / other LangChain models
        from langchain_core.messages import HumanMessage, SystemMessage, AIMessage
        lc_messages = []
        for m in request.messages:
            if m.role == "system":
                lc_messages.append(SystemMessage(content=m.content))
            elif m.role == "user":
                lc_messages.append(HumanMessage(content=m.content))
            elif m.role == "assistant":
                lc_messages.append(AIMessage(content=m.content))

        if request.stream:
            current_model = get_current_model_id()
            completion_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"
            created_at = int(time.time())

            def _gemini_sse_stream() -> Generator[str, None, None]:
                for chunk in llm_instance.stream(lc_messages):
                    delta = chunk.content if hasattr(chunk, 'content') else str(chunk)
                    if delta:
                        payload = {
                            "id": completion_id,
                            "object": "chat.completion.chunk",
                            "created": created_at,
                            "model": current_model,
                            "choices": [{"index": 0, "delta": {"content": delta}, "finish_reason": None}],
                        }
                        yield f"data: {json.dumps(payload)}\n\n"
                yield "data: [DONE]\n\n"

            return StreamingResponse(_gemini_sse_stream(), media_type="text/event-stream")

        response = llm_instance.invoke(lc_messages)
        content = response.content if hasattr(response, 'content') else str(response)
        return {
            "id": f"chatcmpl-{uuid.uuid4().hex[:8]}",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": get_current_model_id(),
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": -1, "completion_tokens": -1, "total_tokens": -1},
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"[ERROR] Chat completion failed: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="Failed to generate response.")


async def generate_embedding_v1(request: EmbeddingV1Request) -> Dict[str, Any]:
    """
    OpenAI-compatible text embeddings. Auto-loads the embedding model if needed.
    """
    _, embedding_lock = get_locks()

    async with embedding_lock:
        embedding_model, _ = get_embedding_model()
        target_alias = request.model
        if embedding_model is None or get_embedding_model_id() != target_alias:
            try:
                model_name, filename = _resolve_model(target_alias)
                local_path = get_local_path(model_name)
                model, processor = load_embedding_model(model_name, filename, local_path)
                set_embedding_model(model, processor)
                set_embedding_model_id(target_alias)
            except Exception as e:
                print(f"[ERROR] Failed to load embedding model: {e}")
                raise HTTPException(status_code=500, detail="Failed to load embedding model.")

    try:
        embedding_model, embedding_processor = get_embedding_model()
        embedding = gen_emb_fn(
            model=embedding_model,
            processor=embedding_processor,
            text=request.input,
        )
        return {
            "object": "list",
            "data": [{"object": "embedding", "embedding": embedding, "index": 0}],
            "model": get_embedding_model_id(),
            "usage": {"prompt_tokens": -1, "total_tokens": -1},
        }
    except Exception as e:
        print(f"[ERROR] Embedding generation failed: {e}")
        raise HTTPException(status_code=500, detail="Failed to generate embedding.")


async def generate_embedding(request: EmbeddingRequest) -> Dict[str, Any]:
    """
    Multimodal embedding (text or image). Used by /util/embedding.
    """
    _, embedding_lock = get_locks()

    if not request.text and not request.image_base64:
        raise HTTPException(status_code=400, detail="Either 'text' or 'image_base64' must be provided.")
    if request.text and request.image_base64:
        raise HTTPException(status_code=400, detail="Only one of 'text' or 'image_base64' can be provided.")

    async with embedding_lock:
        embedding_model, embedding_processor = get_embedding_model()
        if embedding_model is None or embedding_processor is None:
            try:
                model_id = request.model_name
                filename = request.filename
                local_path = get_local_path(model_id)
                model, processor = load_embedding_model(model_id, filename, local_path)
                set_embedding_model(model, processor)
                set_embedding_model_id(model_id)
            except Exception as e:
                print(f"[ERROR] Failed to load embedding model: {e}")
                raise HTTPException(status_code=500, detail="Failed to load embedding model.")

    try:
        embedding_model, embedding_processor = get_embedding_model()
        input_type = "text" if request.text else "image"
        input_content = request.text if request.text else f"base64_image({len(request.image_base64)})"
        embedding = gen_emb_fn(
            model=embedding_model,
            processor=embedding_processor,
            text=request.text,
            image_base64=request.image_base64,
            filename=request.filename,
        )
        return {
            "embedding": embedding,
            "input_type": input_type,
            "input_content": input_content,
            "model_used": get_embedding_model_id(),
            "embedding_dimension": len(embedding),
        }
    except HTTPException:
        raise
    except ValueError as ve:
        raise HTTPException(status_code=400, detail=str(ve))
    except Exception as e:
        print(f"[EMBEDDING] Error: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="Failed to generate embedding.")


async def download_model(request: DownloadModelRequest):
    """Download a GGUF model from HuggingFace, streaming SSE progress events."""
    import json
    model_id = request.model_name
    filename = request.filename
    local_path = get_local_path(model_id)

    print(f"[DOWNLOAD] Request to download {model_id}/{filename}")

    existing = find_local_model(filename, local_path)
    if existing:
        def _already_exists():
            yield f'data: {json.dumps({"status": "complete", "progress": 1.0, "model_path": existing, "message": "Already downloaded"})}\n\n'
        return StreamingResponse(_already_exists(), media_type="text/event-stream")

    return StreamingResponse(
        stream_download_gguf(model_id, filename, local_path, hf_token=request.hf_token),
        media_type="text/event-stream",
    )


def _assert_within_models_dir(path: str, models_dir: str, label: str = "Path") -> None:
    """Raise 400 if `path` is not strictly inside `models_dir`."""
    try:
        if os.path.commonpath([path, models_dir]) != models_dir:
            raise HTTPException(status_code=400, detail=f"{label} is outside the models directory")
    except ValueError:
        # commonpath raises ValueError when paths are on different drives (Windows)
        raise HTTPException(status_code=400, detail=f"{label} is outside the models directory")


async def delete_model(request: DeleteModelRequest) -> Dict[str, Any]:
    """Delete a downloaded GGUF model file and clean up its directory."""
    import shutil

    models_dir = os.path.realpath(
        os.environ.get('AICHAT_MODELS_DIR') or os.path.join(os.getcwd(), 'models')
    )
    model_path = os.path.realpath(request.model_path)

    _assert_within_models_dir(model_path, models_dir, "File")

    if not model_path.endswith('.gguf'):
        raise HTTPException(status_code=400, detail="Only .gguf files may be deleted")

    if not os.path.exists(model_path):
        return {"status": "success", "message": "File already deleted"}

    os.remove(model_path)
    print(f"[DELETE] Removed model file: {model_path}")

    # Remove the parent directory if nothing meaningful remains
    parent = os.path.realpath(os.path.dirname(model_path))
    _assert_within_models_dir(parent, models_dir, "Directory")

    HF_NOISE = {'.gitattributes', '.cache', '.locks', 'blobs', 'refs', 'snapshots'}
    remaining = {f for f in os.listdir(parent) if f not in HF_NOISE}
    if not remaining:
        shutil.rmtree(parent, ignore_errors=True)
        print(f"[DELETE] Removed empty model directory: {parent}")

    return {"status": "success", "message": f"Deleted {os.path.basename(model_path)}"}


def generate_thumbnail(request: ThumbnailRequest) -> Dict[str, Any]:
    """Generate a thumbnail for an image file, including RAW formats."""
    if not os.path.exists(request.file_path):
        raise HTTPException(status_code=404, detail="File not found")
    try:
        ext = os.path.splitext(request.file_path)[1].lower()
        if ext in ['.nef', '.cr2', '.arw', '.dng', '.orf', '.sr2']:
            import rawpy
            with rawpy.imread(request.file_path) as raw:
                rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, bright=1.0)
                img = Image.fromarray(rgb)
        else:
            img = Image.open(request.file_path)
        img.thumbnail((request.width, request.height))
        import io
        import base64
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        return {
            "thumbnail": base64.b64encode(buf.getvalue()).decode('utf-8'),
            "width": img.width,
            "height": img.height,
            "format": "JPEG",
        }
    except Exception as e:
        print(f"[ERROR] Thumbnail generation failed: {e}")
        raise HTTPException(status_code=500, detail=f"Failed to generate thumbnail: {e}")


async def import_pst(request: PstImportRequest):
    """Import and parse an Outlook PST file, streaming JSON results."""
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
