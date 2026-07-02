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
from .skills import apply_skill, list_skills
from .config import DEFAULT_MODEL_ALIAS
from . import model_registry
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
    is_stop_requested, request_stop, reset_stop,
)


def _resolve_embedding_model(alias: str) -> tuple:
    """Resolve an embedding model alias to (hf_repo, filename).
    Embedding models are identified by their HF repo ID directly, not via aichat_models."""
    # Try DB first in case an embedding model was registered
    row = model_registry.lookup(alias)
    if row and row.get('hf_repo') and row.get('file'):
        return row['hf_repo'], row['file']
    # Fall back to treating the alias as a raw HF repo ID (existing behaviour)
    return alias, alias.split('/')[-1] if '/' in alias else alias


def _gemini_user_error(exc: Exception) -> str:
    """Extract a short, human-readable error message from a Gemini API exception."""
    msg = str(exc)
    # Google API core exceptions carry a readable description after the status code
    for marker in ("API key not valid", "API_KEY_INVALID", "INVALID_ARGUMENT",
                   "PERMISSION_DENIED", "RESOURCE_EXHAUSTED", "quota", "model not found"):
        if marker.lower() in msg.lower():
            # Pull the first sentence / bracketed description when available
            import re
            clean = re.search(r'message:\s*"([^"]+)"', msg)
            if clean:
                return f"Gemini error: {clean.group(1)}"
            # Fall through to trimmed raw message
            break
    # Generic fallback: first line of the exception, capped at 200 chars
    first_line = msg.splitlines()[0][:200]
    return f"Gemini error: {first_line}"


def _sse_error_chunk(completion_id: str, created_at: int, model: str, message: str) -> str:
    """Build a single SSE data line that delivers an error as assistant content."""
    payload = {
        "id": completion_id,
        "object": "chat.completion.chunk",
        "created": created_at,
        "model": model,
        "choices": [{"index": 0, "delta": {"content": message}, "finish_reason": "error"}],
    }
    return f"data: {json.dumps(payload)}\n\n"


def _error_chat_response(completion_id: str, created_at: int, model: str, message: str) -> dict:
    """Return an error as a normal non-streaming assistant message so the client displays it."""
    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created_at,
        "model": model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": message}, "finish_reason": "error"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


async def _handle_gemini_request(request: "ChatCompletionRequest"):
    """Create a per-request Gemini client and generate a response with token usage."""
    from langchain_core.messages import HumanMessage, SystemMessage, AIMessage

    completion_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"
    created_at = int(time.time())
    current_model = request.model

    gemini_model_id = request.model  # alias == gemini model ID in the DB
    try:
        llm = load_gemini_model(model_id=gemini_model_id, api_key=request.api_key)
    except ValueError as e:
        error_msg = str(e)
        if request.stream:
            def _key_error_stream() -> Generator[str, None, None]:
                yield _sse_error_chunk(completion_id, created_at, current_model, error_msg)
                yield "data: [DONE]\n\n"
            return StreamingResponse(_key_error_stream(), media_type="text/event-stream")
        return _error_chat_response(completion_id, created_at, current_model, error_msg)

    lc_messages = []
    for m in request.messages:
        if m.role == "system":
            lc_messages.append(SystemMessage(content=m.content))
        elif m.role == "user":
            lc_messages.append(HumanMessage(content=m.content))
        elif m.role == "assistant":
            lc_messages.append(AIMessage(content=m.content))

    if request.stream:
        def _gemini_sse_stream() -> Generator[str, None, None]:
            reset_stop()
            accumulated = None
            try:
                for chunk in llm.stream(lc_messages):
                    if is_stop_requested():
                        break
                    delta = chunk.content if hasattr(chunk, 'content') else str(chunk)
                    # Accumulate chunks so the final result carries usage_metadata
                    accumulated = chunk if accumulated is None else accumulated + chunk
                    if delta:
                        payload = {
                            "id": completion_id,
                            "object": "chat.completion.chunk",
                            "created": created_at,
                            "model": current_model,
                            "choices": [{"index": 0, "delta": {"content": delta}, "finish_reason": None}],
                        }
                        yield f"data: {json.dumps(payload)}\n\n"
            except Exception as e:
                print(f"[ERROR] Gemini stream failed: {e}")
                yield _sse_error_chunk(completion_id, created_at, current_model, _gemini_user_error(e))
                yield "data: [DONE]\n\n"
                return

            # Final chunk with finish_reason and token usage
            final: dict = {
                "id": completion_id,
                "object": "chat.completion.chunk",
                "created": created_at,
                "model": current_model,
                "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
            }
            usage_meta = getattr(accumulated, 'usage_metadata', None) if accumulated else None
            if usage_meta:
                input_t = usage_meta.get("input_tokens", 0) if isinstance(usage_meta, dict) else getattr(usage_meta, 'input_tokens', 0)
                output_t = usage_meta.get("output_tokens", 0) if isinstance(usage_meta, dict) else getattr(usage_meta, 'output_tokens', 0)
                total_t = usage_meta.get("total_tokens", 0) if isinstance(usage_meta, dict) else getattr(usage_meta, 'total_tokens', 0)
                if total_t:
                    final["usage"] = {
                        "prompt_tokens": input_t,
                        "completion_tokens": output_t,
                        "total_tokens": total_t,
                    }
            yield f"data: {json.dumps(final)}\n\n"
            yield "data: [DONE]\n\n"

        return StreamingResponse(_gemini_sse_stream(), media_type="text/event-stream")

    # Non-streaming
    try:
        response = llm.invoke(lc_messages)
    except Exception as e:
        print(f"[ERROR] Gemini invoke failed: {e}")
        return _error_chat_response(completion_id, created_at, current_model, _gemini_user_error(e))

    content = response.content if hasattr(response, 'content') else str(response)
    usage: dict = {"prompt_tokens": -1, "completion_tokens": -1, "total_tokens": -1}
    if hasattr(response, 'usage_metadata') and response.usage_metadata:
        meta = response.usage_metadata
        usage = {
            "prompt_tokens": meta.get("input_tokens", -1),
            "completion_tokens": meta.get("output_tokens", -1),
            "total_tokens": meta.get("total_tokens", -1),
        }
    return {
        "id": completion_id,
        "object": "chat.completion",
        "created": created_at,
        "model": current_model,
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": usage,
    }


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


def _strip_image_content(messages: list) -> list:
    """Extract only text from multimodal messages for text-only models."""
    result = []
    for msg in messages:
        content = msg.get('content')
        if isinstance(content, list):
            text_parts = [p['text'] for p in content if p.get('type') == 'text' and p.get('text')]
            msg = {**msg, 'content': ' '.join(text_parts)}
        result.append(msg)
    return result


async def generate_chat_completion(request: ChatCompletionRequest):
    """
    OpenAI-compatible chat completion. Auto-loads the requested model if it
    differs from the currently loaded one.
    """
    model_lock, _ = get_locks()
    target_alias = request.model or DEFAULT_MODEL_ALIAS

    db_row = model_registry.lookup(target_alias)

    # Cloud models (Gemini) are stateless API calls — no local loading needed.
    if db_row and db_row.get('group') == 'gemini':
        return await _handle_gemini_request(request)

    # Load or switch local GGUF model if needed (compare by alias)
    if get_llm_instance() is None or target_alias != get_current_model_id():
        async with model_lock:
            # Re-check inside the lock to avoid double-loading
            if get_llm_instance() is None or target_alias != get_current_model_id():
                mmproj_path = None
                chat_handler_name = db_row.get('chat_handler') if db_row else None
                model_name = target_alias

                # When the client sends an explicit file path, use it directly.
                if request.model_path:
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
                    # No client-provided mmproj: fall back to DB row
                    if mmproj_path is None and db_row:
                        mmproj_val = db_row.get('mmproj') or ''
                        if mmproj_val:
                            if os.path.isabs(mmproj_val) and os.path.exists(mmproj_val):
                                mmproj_path = mmproj_val
                            else:
                                model_dir = os.path.dirname(model_path)
                                mmproj_path = find_local_model(mmproj_val, model_dir)
                            if mmproj_path:
                                print(f"[LOADER] Found mmproj via DB fallback: {mmproj_path}")
                            else:
                                print(f"[LOADER] DB mmproj '{mmproj_val}' not found — text-only mode")
                else:
                    # DB-based resolution
                    if not db_row:
                        raise HTTPException(
                            status_code=404,
                            detail=f"Model '{target_alias}' not found in the model registry. "
                                   f"Add it in Settings → AI Chat Models first."
                        )
                    file_val = db_row.get('file') or ''
                    mmproj_val = db_row.get('mmproj') or ''
                    hf_repo = db_row.get('hf_repo') or ''
                    model_name = hf_repo or target_alias

                    if os.path.isabs(file_val) and os.path.exists(file_val):
                        # Downloaded model — use stored path directly
                        model_path = file_val
                        if os.path.isabs(mmproj_val) and os.path.exists(mmproj_val):
                            mmproj_path = mmproj_val
                    elif hf_repo and file_val:
                        # Bundled or HF-cache model — discover by filename
                        local_path = get_local_path(hf_repo)
                        model_path = find_local_model(file_val, local_path)
                        if model_path is None:
                            raise HTTPException(
                                status_code=404,
                                detail=f"Model '{target_alias}' ({file_val}) not found locally. "
                                       f"Use /util/download-model to download it first."
                            )
                        if mmproj_val and not os.path.isabs(mmproj_val):
                            mmproj_path = find_local_model(mmproj_val, local_path)
                            if not mmproj_path:
                                print(f"[LOADER] mmproj '{mmproj_val}' not found — text-only mode")
                    else:
                        raise HTTPException(
                            status_code=404,
                            detail=f"Model '{target_alias}' has no file path configured. "
                                   f"Download it in Settings → AI Chat Models first."
                        )

                old_llm = get_llm_instance()
                if old_llm is not None:
                    print("[LOADER] Freeing previous model from memory...")
                    set_llm_instance(None)
                    del old_llm
                    gc.collect()
                set_current_model_id(None)

                try:
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
        messages = apply_skill(messages)

        # If the model has no vision handler, strip image_url parts so raw base64
        # doesn't get tokenized as text (which would consume hundreds of thousands of tokens).
        if hasattr(llm_instance, 'create_chat_completion') and not getattr(llm_instance, 'chat_handler', None):
            messages = _strip_image_content(messages)

        # llama_cpp.Llama (local GGUF, text or vision)
        kwargs: Dict[str, Any] = {"messages": messages}
        if request.temperature is not None:
            kwargs["temperature"] = request.temperature
        if request.max_tokens is not None:
            kwargs["max_tokens"] = request.max_tokens

        if request.stream:
            current_model = get_current_model_id()

            def _sse_stream() -> Generator[str, None, None]:
                reset_stop()
                for chunk in llm_instance.create_chat_completion(
                    stream=True, **kwargs
                ):
                    if is_stop_requested():
                        break
                    chunk["model"] = current_model
                    yield f"data: {json.dumps(chunk)}\n\n"
                yield "data: [DONE]\n\n"

            return StreamingResponse(_sse_stream(), media_type="text/event-stream")

        result = llm_instance.create_chat_completion(**kwargs)
        result["model"] = get_current_model_id() or result.get("model", "unknown")
        return result

    except HTTPException:
        raise
    except Exception as e:
        print(f"[ERROR] Chat completion failed: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="Failed to generate response.")


async def stop_generation() -> Dict[str, Any]:
    """Signal the active streaming generation to stop after the current token."""
    request_stop()
    return {"status": "stopping"}


async def get_skills() -> Dict[str, Any]:
    """Return the built-in skill registry for client autocomplete."""
    return {"skills": list_skills()}


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
                model_name, filename = _resolve_embedding_model(target_alias)
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

    if parent != models_dir:
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
