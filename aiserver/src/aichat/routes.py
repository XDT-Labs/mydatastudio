"""
API route handlers.
"""
import asyncio
import gc
import os
import json
import time
import uuid
from typing import Dict, Any, Generator, Optional

from fastapi import HTTPException, Request
from fastapi.concurrency import run_in_threadpool
from fastapi.responses import StreamingResponse
from PIL import Image
try:
    from pillow_heif import register_heif_opener

    # Registers a HEIF/HEIC opener with PIL.Image.open so generate_thumbnail's
    # plain Image.open() branch (below) can decode .heic/.heif bytes with no
    # format-specific code path, the same way it already handles JPEG/PNG/etc.
    register_heif_opener()
except ImportError:
    pass

from .models import (
    ChatCompletionRequest, EmbeddingV1Request,
    EmbeddingRequest, DownloadModelRequest, DeleteModelRequest, ThumbnailRequest, PstImportRequest,
    ExtractTextRequest,
)
from .skills import apply_skill, list_skills
from .config import DEFAULT_MODEL_ALIAS
from . import model_registry
from . import document_extractor
from .pst_parser import PstParser
from .model_manager import (
    load_local_model,
    load_embedding_model,
    generate_embeddings as gen_emb_fn,
    load_gemini_model,
    load_claude_model,
    load_openai_model,
    load_grok_model,
)
from .utils import (
    get_local_path, find_local_model, download_gguf_model, stream_download_gguf,
    stream_download_snapshot, is_snapshot_downloaded, _resolve_models_base,
    resolve_data_roots,
)
from .state import (
    get_llm_instance, set_llm_instance,
    get_current_model_id, set_current_model_id,
    get_embedding_model, set_embedding_model,
    get_embedding_model_id, set_embedding_model_id,
    get_locks, get_generation_lock,
    is_stop_requested, request_stop, register_stream, unregister_stream,
    active_stream_count,
)


# Returned as the 409 detail when the single local-model generation slot is
# already taken. The shared llama_cpp instance has one decoder state, so
# generations cannot overlap; this app is single-user and the client serializes
# its own requests, so a second concurrent generation is a caller bug worth
# reporting loudly rather than a queue worth building.
GENERATION_BUSY_DETAIL = (
    "A generation is already in progress. Wait for it to finish, "
    "or POST /v1/chat/stop to cancel it."
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


def _embedding_model_downloaded(model_id: str, filename: Optional[str]) -> bool:
    """Local-disk-only check mirroring load_embedding_model()'s own routing
    (Transformers snapshot for VL models, single GGUF file otherwise).

    Callers must check this before invoking load_embedding_model() — without
    it, an embedding request for a model that isn't downloaded yet falls
    through to Transformers' from_pretrained(model_id), which silently
    triggers its own blocking HuggingFace download from inside the request
    path instead of failing fast and pointing the caller at
    /util/download-model (which the client already drives with progress UI).
    """
    local_path = get_local_path(model_id)
    if filename is None or "vl" in model_id.lower():
        return is_snapshot_downloaded(model_id, local_path)
    return find_local_model(filename, local_path) is not None


# Cloud chat providers, all wrapped as LangChain chat models with the same
# .stream() / .invoke() / .usage_metadata interface — one generic handler
# (_handle_cloud_request) drives all of them; these maps just parameterize it.
_CLOUD_LOADERS = {
    "gemini": load_gemini_model,
    "claude": load_claude_model,
    "openai": load_openai_model,
    "grok": load_grok_model,
}
_CLOUD_LABELS = {
    "gemini": "Gemini",
    "claude": "Claude",
    "openai": "OpenAI",
    "grok": "Grok",
}


def _cloud_user_error(provider: str, exc: Exception) -> str:
    """Extract a short, human-readable error message from a cloud provider API exception."""
    import re
    label = _CLOUD_LABELS.get(provider, provider)
    msg = str(exc)
    # Most provider SDKs (Google/OpenAI/Anthropic) embed a readable description
    # in a message: "..." or 'message': '...' field within a longer exception repr.
    clean = re.search(r'''message['"]?\s*[:=]\s*['"]([^'"]+)['"]''', msg)
    if clean:
        return f"{label} error: {clean.group(1)}"
    # Generic fallback: first line of the exception, capped at 200 chars
    first_line = msg.splitlines()[0][:200]
    return f"{label} error: {first_line}"


def _gemini_user_error(exc: Exception) -> str:
    """Extract a short, human-readable error message from a Gemini API exception."""
    return _cloud_user_error("gemini", exc)


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


async def _handle_cloud_request(provider: str, request: "ChatCompletionRequest"):
    """Create a per-request cloud LLM client (gemini/claude/openai/grok) and generate a response with token usage."""
    from langchain_core.messages import HumanMessage, SystemMessage, AIMessage

    completion_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"
    created_at = int(time.time())
    current_model = request.model
    label = _CLOUD_LABELS[provider]
    load_model = _CLOUD_LOADERS[provider]

    try:
        llm = load_model(model_id=request.model, api_key=request.api_key)
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
        def _cloud_sse_stream() -> Generator[str, None, None]:
            register_stream(completion_id)
            accumulated = None
            try:
                for chunk in llm.stream(lc_messages):
                    if is_stop_requested(completion_id):
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
                print(f"[ERROR] {label} stream failed: {e}")
                yield _sse_error_chunk(completion_id, created_at, current_model, _cloud_user_error(provider, e))
                yield "data: [DONE]\n\n"
                return
            finally:
                unregister_stream(completion_id)

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

        return StreamingResponse(_cloud_sse_stream(), media_type="text/event-stream")

    # Non-streaming
    try:
        response = llm.invoke(lc_messages)
    except Exception as e:
        print(f"[ERROR] {label} invoke failed: {e}")
        return _error_chat_response(completion_id, created_at, current_model, _cloud_user_error(provider, e))

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


async def _handle_gemini_request(request: "ChatCompletionRequest"):
    return await _handle_cloud_request("gemini", request)


async def _handle_claude_request(request: "ChatCompletionRequest"):
    return await _handle_cloud_request("claude", request)


async def _handle_openai_request(request: "ChatCompletionRequest"):
    return await _handle_cloud_request("openai", request)


async def _handle_grok_request(request: "ChatCompletionRequest"):
    return await _handle_cloud_request("grok", request)


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

    # Cloud models (Gemini/Claude/OpenAI/Grok) are stateless API calls — no local loading needed.
    if db_row:
        provider = db_row.get('group') if db_row.get('group') in _CLOUD_LOADERS else None
    else:
        # Fallback for when the DB is inaccessible (e.g. remote server)
        alias_lower = target_alias.lower()
        if alias_lower.startswith('gemini'):
            provider = 'gemini'
        elif alias_lower.startswith('claude'):
            provider = 'claude'
        elif alias_lower.startswith(('gpt', 'o1', 'o3')):
            provider = 'openai'
        elif alias_lower.startswith('grok'):
            provider = 'grok'
        else:
            provider = None

    if provider == 'gemini':
        return await _handle_gemini_request(request)
    if provider == 'claude':
        return await _handle_claude_request(request)
    if provider == 'openai':
        return await _handle_openai_request(request)
    if provider == 'grok':
        return await _handle_grok_request(request)

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
        if request.response_format is not None:
            kwargs["response_format"] = request.response_format

        if request.stream:
            current_model = get_current_model_id()
            stop_id = f"chatcmpl-{uuid.uuid4().hex[:8]}"
            created_at = int(time.time())

            # Claim the generation slot *before* the response starts. Acquiring
            # non-blocking is what keeps the lock off the yield path: the holder
            # may sit parked at a yield waiting on a slow client, but nobody is
            # ever queued behind it — a second caller is refused immediately
            # instead of hanging on a 200 whose body never arrives.
            lock = get_generation_lock()
            if not lock.acquire(blocking=False):
                raise HTTPException(status_code=409, detail=GENERATION_BUSY_DETAIL)

            def _sse_stream() -> Generator[str, None, None]:
                # Ownership of the lock passes to this generator; its finally is
                # the sole release point (it also runs on GeneratorExit when the
                # client disconnects mid-stream).
                register_stream(stop_id)
                try:
                    for chunk in llm_instance.create_chat_completion(
                        stream=True, **kwargs
                    ):
                        if is_stop_requested(stop_id):
                            break
                        # Stable id the client echoes back to target /v1/chat/stop.
                        chunk["id"] = stop_id
                        chunk["model"] = current_model
                        yield f"data: {json.dumps(chunk)}\n\n"
                    yield "data: [DONE]\n\n"
                except Exception as e:
                    # Same contract as the cloud path: the client always gets a
                    # terminal event. Without this the generator just stops and
                    # the client sees a bare connection drop with no reason.
                    print(f"[ERROR] local generation stream failed: {e}")
                    yield _sse_error_chunk(
                        stop_id, created_at, current_model, "Generation failed."
                    )
                    yield "data: [DONE]\n\n"
                finally:
                    unregister_stream(stop_id)
                    lock.release()

            try:
                return StreamingResponse(_sse_stream(), media_type="text/event-stream")
            except BaseException:
                # Nothing between the acquire and here should raise, but a leaked
                # generation lock would 409 every later request until restart, so
                # it is worth the guard.
                lock.release()
                raise

        # Same slot, same refusal: the non-streaming path shares the lock with
        # any active stream. Run the blocking call off the event loop.
        lock = get_generation_lock()
        if not lock.acquire(blocking=False):
            raise HTTPException(status_code=409, detail=GENERATION_BUSY_DETAIL)
        try:
            result = await asyncio.to_thread(
                lambda: llm_instance.create_chat_completion(**kwargs)
            )
        finally:
            lock.release()
        result["model"] = get_current_model_id() or result.get("model", "unknown")
        return result

    except HTTPException:
        raise
    except Exception as e:
        print(f"[ERROR] Chat completion failed: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail="Failed to generate response.")


async def stop_generation(request: Request) -> Dict[str, Any]:
    """Signal a streaming generation to stop after the current token.

    The body may carry ``{"id": "<completion id>"}`` to target a specific
    stream. With no id (or an unparseable body) the request is only honoured
    when exactly one generation is registered — the unambiguous "stop the
    active stream" case the client hits when it cancels before the first chunk
    arrives and so has no id yet. With several streams running, an untargeted
    stop would cancel unrelated generations, so it is refused instead.
    """
    gen_id: Optional[str] = None
    try:
        body = await request.json()
        if isinstance(body, dict):
            gen_id = body.get("id")
    except Exception:
        gen_id = None

    if gen_id is None:
        active = active_stream_count()
        if active != 1:
            return {"status": "ambiguous", "active": active}

    request_stop(gen_id)
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
            model_name, filename = _resolve_embedding_model(target_alias)
            if not _embedding_model_downloaded(model_name, filename):
                raise HTTPException(
                    status_code=503,
                    detail=f"Embedding model '{target_alias}' is not downloaded yet. Download it via /util/download-model first.",
                )
            try:
                local_path = get_local_path(model_name)
                model, processor = load_embedding_model(model_name, filename, local_path)
                set_embedding_model(model, processor)
                set_embedding_model_id(target_alias)
            except Exception as e:
                print(f"[ERROR] Failed to load embedding model: {e}")
                raise HTTPException(status_code=500, detail="Failed to load embedding model.")

    try:
        embedding_model, embedding_processor = get_embedding_model()
        embeddings = await run_in_threadpool(
            gen_emb_fn,
            model=embedding_model,
            processor=embedding_processor,
            texts=[request.input],
        )
        return {
            "object": "list",
            "data": [{"object": "embedding", "embedding": embeddings[0], "index": 0}],
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

    if not request.texts and not request.images_base64:
        raise HTTPException(status_code=400, detail="Either 'texts' or 'images_base64' must be provided.")
    if request.texts and request.images_base64:
        raise HTTPException(status_code=400, detail="Only one of 'texts' or 'images_base64' can be provided.")

    async with embedding_lock:
        embedding_model, embedding_processor = get_embedding_model()
        if embedding_model is None or embedding_processor is None:
            model_id = request.model_name
            filename = request.filename
            if not _embedding_model_downloaded(model_id, filename):
                raise HTTPException(
                    status_code=503,
                    detail=f"Embedding model '{model_id}' is not downloaded yet. Download it via /util/download-model first.",
                )
            try:
                local_path = get_local_path(model_id)
                model, processor = load_embedding_model(model_id, filename, local_path)
                set_embedding_model(model, processor)
                set_embedding_model_id(model_id)
            except Exception as e:
                print(f"[ERROR] Failed to load embedding model: {e}")
                raise HTTPException(status_code=500, detail="Failed to load embedding model.")

    try:
        embedding_model, embedding_processor = get_embedding_model()
        input_type = "text" if request.texts else "image"
        count = len(request.texts or request.images_base64)
        # The forward pass is synchronous and holds the GIL through Python-level
        # work, so running it inline would block uvicorn's event loop for its
        # whole duration — the next request would not even be read off the
        # socket until this one finished. Off-loop it stays cancellable and the
        # server keeps answering /util/model-status while a batch is running.
        embeddings = await run_in_threadpool(
            gen_emb_fn,
            model=embedding_model,
            processor=embedding_processor,
            texts=request.texts,
            images_base64=request.images_base64,
            filename=request.filename,
        )
        return {
            "embeddings": embeddings,
            "input_type": input_type,
            "input_count": count,
            "model_used": get_embedding_model_id(),
            "embedding_dimension": len(embeddings[0]) if embeddings else 0,
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
    """Download a model from HuggingFace, streaming SSE progress events.

    Downloads a single GGUF file when `filename` is set, or the entire repo
    snapshot when it's null (multi-file Transformers models e.g. embedding models).
    """
    import json
    model_id = request.model_name
    filename = request.filename
    local_path = get_local_path(model_id)

    if filename is None:
        print(f"[DOWNLOAD] Request to download snapshot {model_id}")
        return StreamingResponse(
            stream_download_snapshot(model_id, local_path, hf_token=request.hf_token),
            media_type="text/event-stream",
        )

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


async def check_model_status(request: DownloadModelRequest) -> Dict[str, Any]:
    """Local-only check for whether a model (GGUF file or full snapshot) is
    already downloaded. Never hits the network — used to decide whether a
    download needs to run without re-verifying against HuggingFace on every launch.
    """
    model_id = request.model_name
    filename = request.filename
    local_path = get_local_path(model_id)

    if filename is None:
        exists = is_snapshot_downloaded(model_id, local_path)
        return {"exists": exists, "model_path": local_path if exists else None}

    existing = find_local_model(filename, local_path)
    return {"exists": existing is not None, "model_path": existing}


def _assert_within_roots(path: str, roots: list, label: str = "Path") -> str:
    """Return realpath(path) if it lives inside one of `roots`, else raise 403.

    `roots` are treated as trusted prefixes; the check resolves symlinks (via
    realpath) so a symlink inside an allowed root that points elsewhere is caught.
    A trailing os.sep is required on the prefix so `/a/b` does not match `/a/bc`.
    """
    real = os.path.realpath(path)
    for root in roots:
        if not root:
            continue
        real_root = os.path.realpath(root)
        if real == real_root or real.startswith(real_root + os.sep):
            return real
    # Logged explicitly, not left to the access log: uvicorn's per-request line is
    # off, and even with it on a bare "403" never said *which* path was refused or
    # what it was checked against. A misconfigured root makes every import fail
    # with no local trace of why.
    # flush: this is the only trace of a refusal, and a server killed before its
    # buffer drains would otherwise lose it — which is how it stayed invisible.
    print(
        f"[ERROR] {label} rejected: {real!r} is not inside any allowed root "
        f"({[os.path.realpath(r) for r in roots if r]})",
        flush=True,
    )
    raise HTTPException(status_code=403, detail=f"{label} is outside the allowed directories")


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
    """Generate a thumbnail from base64 image bytes, including RAW formats.

    The client sends the source bytes (not a path), so the server never opens a
    file off disk — this is the structural fix for AUDIT H2. RAW decoding
    (rawpy) is selected by the client-supplied ``is_raw`` flag rather than a
    filename extension.
    """
    import io
    import base64

    payload = request.image_base64
    if payload.startswith("data:"):
        payload = payload.split(",", 1)[1]
    try:
        raw_bytes = base64.b64decode(payload)
    except Exception as e:
        print(f"[ERROR] Invalid base64 image payload: {e}")
        raise HTTPException(status_code=400, detail="Invalid image payload.")

    try:
        if request.is_raw:
            import rawpy
            with rawpy.imread(io.BytesIO(raw_bytes)) as raw:
                rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, bright=1.0)
                img = Image.fromarray(rgb)
        else:
            img = Image.open(io.BytesIO(raw_bytes))
        img.thumbnail((request.width, request.height))
        # JPEG can't hold alpha/palette modes — normalize to RGB before saving.
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
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
        raise HTTPException(status_code=500, detail="Failed to generate thumbnail.")


async def extract_text(request: ExtractTextRequest) -> Dict[str, Any]:
    """Extract a document to markdown and chunk it, for search Phase 7 (§18).

    Runs off the event loop: conversion is seconds to tens of seconds on a
    large file, and unlike the embedding endpoints there is no shared model
    lock to serialize behind — docling holds no global state, so concurrent
    extractions are safe and only bounded by the threadpool.

    The one thing a caller cannot recover from is the chunker not returning:
    §18a-2 measured a spreadsheet exceeding ten minutes with no way to
    interrupt it, so oversized input is *declined* rather than attempted. Those
    responses come back with ``gated: true`` and the full text in a single
    chunk — searchable lexically, just not embedded.
    """
    import base64

    payload = request.file_base64
    if payload.startswith("data:"):
        payload = payload.split(",", 1)[1]
    try:
        raw_bytes = base64.b64decode(payload)
    except Exception as e:
        print(f"[ERROR] Invalid base64 document payload: {e}")
        raise HTTPException(status_code=400, detail="Invalid document payload.")

    try:
        result = await run_in_threadpool(
            document_extractor.extract, raw_bytes, request.filename
        )
    except document_extractor.ExtractionUnavailable as e:
        # 503, not 422: the document is fine, this server cannot read the
        # format yet. The client must not spend a retry attempt on it, or the
        # file retires permanently before the dependency ever arrives (§18i).
        print(f"[WARN] Extraction unavailable for {request.filename!r}: {e}")
        raise HTTPException(status_code=503, detail=str(e))
    except document_extractor.UnsupportedFormat as e:
        # 415, not 400: the request is well-formed, we decline the media type.
        # The client uses this to mark the file permanently unprocessable
        # rather than retrying it (§18i).
        raise HTTPException(status_code=415, detail=str(e))
    except Exception as e:
        # A parse failure is unprocessable *content* — §18i counts it toward
        # embedding_attempts, unlike a transport error. 422 is what tells the
        # two apart on the client side. Measured: ~29% of this archive's
        # non-PDF documents land here (§18a-1).
        print(f"[ERROR] Document extraction failed ({request.filename!r}): {e}")
        raise HTTPException(status_code=422, detail=f"Could not extract document: {e}")

    return {
        "format": result.fmt,
        "markdown_chars": result.markdown_chars,
        "gated": result.gated,
        "chunks": [
            {
                "chunk_index": c.chunk_index,
                "text": c.text,
                "page": c.page,
                "heading_path": c.heading_path,
                "char_start": c.char_start,
                "char_end": c.char_end,
            }
            for c in result.chunks
        ],
    }


async def import_pst(request: PstImportRequest):
    """Import and parse an Outlook PST file, streaming JSON results."""
    file_path = os.path.realpath(request.file_path)
    if not file_path.lower().endswith('.pst'):
        raise HTTPException(status_code=400, detail="file_path must point to a .pst file")
    if not os.path.isfile(file_path):
        raise HTTPException(status_code=400, detail="file_path does not exist")
    # Confine attachment extraction to the app's own data dirs so a caller can't
    # redirect writes to an arbitrary location (AUDIT M1). The parser additionally
    # keeps every write inside this output_dir.
    output_dir = _assert_within_roots(request.output_dir, resolve_data_roots(), "output_dir")

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
