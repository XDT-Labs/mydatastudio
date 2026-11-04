"""
Model loading and management functionality.

This module handles loading and managing GGUF models via LlamaCpp and
Google Gemini API models. It provides the core functionality for both
chat and embedding models.
"""
import logging
import os
import sys
import torch
from PIL import Image
import base64
import io
from typing import Any, List, Optional

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    SentenceTransformer = None

EMBEDDING_DIMENSION = 768
QUERY_PROMPT = "task: search result | query: "
DOCUMENT_PROMPT = "title: none | text: "

from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_openai import ChatOpenAI
from langchain_anthropic import ChatAnthropic
from langchain_community.llms import LlamaCpp

from .config import MAX_NEW_TOKENS, TEMPERATURE, DO_SAMPLE
from .utils import find_local_model, download_gguf_model


# ggml_log_level values, from ggml.h.
GGML_LOG_LEVEL_INFO = 1
GGML_LOG_LEVEL_WARN = 2
GGML_LOG_LEVEL_ERROR = 3
GGML_LOG_LEVEL_DEBUG = 4
GGML_LOG_LEVEL_CONT = 5


class MtmdLogFilter:
    """Decides which lines from libmtmd's own logger reach stderr.

    Two separate leaks, both through this one logger.

    mtmd echoes every text chunk it tokenizes, at INFO, with the chunk's full
    contents — one document description put 62k characters of prompt into the
    log. And vision encoding narrates itself a handful of lines per image
    ("encoding image slice...", "image slice encoded in 52 ms",
    "clip_image_batch_encode: copying image 1/1 to input buffer"), which a
    cluster labelling pass multiplies by every thumbnail it sends. Each line
    crosses the pipe to Flutter and is logged again there.

    Only errors survive, rather than the usual warnings-and-above, because
    libmtmd's severity field does not mean what it says: measured against
    gemma-4-12B, the four per-image progress lines from mtmd-helper arrive at
    GGML_LOG_LEVEL_WARN while clip's own output arrives at INFO. A level-based
    rule that trusts WARN therefore keeps exactly the noise it was written to
    remove. Running the server at debug still brings every line back, which is
    where to look when a warning from this library actually matters.
    """

    def __init__(self, keep_chatter: bool):
        self.keep_chatter = keep_chatter
        # A CONT line continues the one before it, so it has to inherit that
        # line's fate — dropping the header and keeping its tail would print a
        # fragment with nothing to attach to.
        self._emitted = True

    def should_emit(self, level: int) -> bool:
        if level == GGML_LOG_LEVEL_CONT:
            return self._emitted
        self._emitted = self.keep_chatter or level == GGML_LOG_LEVEL_ERROR
        return self._emitted


# ctypes callbacks are collected as soon as Python stops pointing at them, and
# libmtmd would then be calling into freed memory — so the live one is held here.
_mtmd_log_callback = None


def quiet_mtmd_logging() -> None:
    """Put libmtmd's logger behind [MtmdLogFilter].

    libmtmd keeps a logger state of its own, separate from libllama's, so
    llama_cpp's `verbose=False` — which only reaches `llama_log_set` — never
    touches it and its per-image output goes straight to stderr.

    Quieting logs must never be the reason a model fails to load, so a binding
    that turns out not to exist is reported and shrugged off.
    """
    global _mtmd_log_callback
    if _mtmd_log_callback is not None:
        return

    try:
        import ctypes
        import llama_cpp
        import llama_cpp.mtmd_cpp as mtmd_cpp

        log_filter = MtmdLogFilter(
            keep_chatter=logging.getLogger().getEffectiveLevel() < logging.INFO
        )

        @llama_cpp.llama_log_callback
        def forward(level: int, text: bytes, user_data):
            # Nothing may escape. Native code calls straight into here, and
            # CPython answers an exception at that boundary by writing an
            # "Exception ignored on calling ctypes callback function"
            # traceback to stderr — several lines per image, which is worse
            # than the output this exists to suppress. stderr is the likely
            # culprit too: it is a pipe to Flutter, so a client that has gone
            # away turns every write into a BrokenPipeError, and the traceback
            # would go down the same dead pipe. A dropped log line is the
            # cheapest possible failure here.
            try:
                if log_filter.should_emit(level) and text:
                    sys.stderr.write(text.decode("utf-8", "replace"))
                    sys.stderr.flush()
            except Exception:
                pass

        _mtmd_log_callback = forward
        mtmd_cpp.mtmd_log_set(forward, ctypes.c_void_p(0))
        mtmd_cpp.mtmd_helper_log_set(forward, ctypes.c_void_p(0))
    except Exception as e:
        print(f"[LOADER] Could not quiet libmtmd logging: {e}")


def load_gemini_model(model_id: str = "gemini-2.0-flash", api_key: Optional[str] = None) -> ChatGoogleGenerativeAI:
    """
    Initializes a connection to the Google Gemini API.

    Args:
        model_id: The Gemini model ID (e.g. "gemini-2.0-flash", "gemini-1.5-pro").
        api_key: Google API key. Falls back to GOOGLE_API_KEY env var if not provided.

    Raises:
        ValueError: If no API key is available.
    """
    resolved_key = api_key or os.environ.get("GOOGLE_API_KEY")
    if not resolved_key:
        raise ValueError(
            "Gemini API key required. Pass 'api_key' in the request or set the GOOGLE_API_KEY environment variable."
        )

    print(f"[LOADER] Initializing Google Gemini client for model: {model_id}")
    return ChatGoogleGenerativeAI(
        model=model_id,
        google_api_key=resolved_key,
        temperature=TEMPERATURE,
    )


def load_claude_model(model_id: str = "claude-sonnet-4-5", api_key: Optional[str] = None) -> ChatAnthropic:
    """
    Initializes a connection to the Anthropic Claude API.

    Args:
        model_id: The Claude model ID (e.g. "claude-sonnet-4-5", "claude-opus-4-8").
        api_key: Anthropic API key. Falls back to ANTHROPIC_API_KEY env var if not provided.

    Raises:
        ValueError: If no API key is available.
    """
    resolved_key = api_key or os.environ.get("ANTHROPIC_API_KEY")
    if not resolved_key:
        raise ValueError(
            "Claude API key required. Pass 'api_key' in the request or set the ANTHROPIC_API_KEY environment variable."
        )

    print(f"[LOADER] Initializing Anthropic Claude client for model: {model_id}")
    return ChatAnthropic(
        model=model_id,
        api_key=resolved_key,
        temperature=TEMPERATURE,
    )


# o1/o3/o4 reasoning models reject any temperature other than the API default.
_OPENAI_REASONING_PREFIXES = ("o1", "o3", "o4")


def load_openai_model(model_id: str = "gpt-4o", api_key: Optional[str] = None) -> ChatOpenAI:
    """
    Initializes a connection to the OpenAI API.

    Args:
        model_id: The OpenAI model ID (e.g. "gpt-4o", "o3").
        api_key: OpenAI API key. Falls back to OPENAI_API_KEY env var if not provided.

    Raises:
        ValueError: If no API key is available.
    """
    resolved_key = api_key or os.environ.get("OPENAI_API_KEY")
    if not resolved_key:
        raise ValueError(
            "OpenAI API key required. Pass 'api_key' in the request or set the OPENAI_API_KEY environment variable."
        )

    print(f"[LOADER] Initializing OpenAI client for model: {model_id}")
    kwargs: dict = {"model": model_id, "api_key": resolved_key}
    if not model_id.lower().startswith(_OPENAI_REASONING_PREFIXES):
        kwargs["temperature"] = TEMPERATURE
    return ChatOpenAI(**kwargs)


def load_grok_model(model_id: str = "grok-3", api_key: Optional[str] = None) -> ChatOpenAI:
    """
    Initializes a connection to xAI's Grok API via its OpenAI-compatible endpoint.

    Args:
        model_id: The Grok model ID (e.g. "grok-3").
        api_key: xAI API key. Falls back to XAI_API_KEY env var if not provided.

    Raises:
        ValueError: If no API key is available.
    """
    resolved_key = api_key or os.environ.get("XAI_API_KEY")
    if not resolved_key:
        raise ValueError(
            "Grok API key required. Pass 'api_key' in the request or set the XAI_API_KEY environment variable."
        )

    print(f"[LOADER] Initializing xAI Grok client for model: {model_id}")
    return ChatOpenAI(
        model=model_id,
        api_key=resolved_key,
        base_url="https://api.x.ai/v1",
        temperature=TEMPERATURE,
    )


def load_local_model(
    model_name: str,
    model_path: str,
    clip_model_path: Optional[str] = None,
    chat_handler_name: Optional[str] = None,
):
    """
    Load a GGUF model directly via llama_cpp.Llama.

    Args:
        model_name (str): HF repo ID or display name (used for logging only)
        model_path (str): Full absolute path to the .gguf file
        clip_model_path (str | None): Path to mmproj .gguf for vision; None = text-only
        chat_handler_name (str | None): llama_chat_format class name (e.g. 'Gemma4ChatHandler')
    """
    import llama_cpp

    print(f"[LOADER] Loading GGUF model: {model_name} from {model_path}")

    chat_handler = None
    if clip_model_path:
        handler_cls_name = chat_handler_name or "Gemma4ChatHandler"
        from llama_cpp import llama_chat_format
        handler_cls = getattr(llama_chat_format, handler_cls_name, None)
        if handler_cls is None:
            print(f"[LOADER] Unknown chat handler '{handler_cls_name}', falling back to Gemma4ChatHandler")
            handler_cls = llama_chat_format.Gemma4ChatHandler
        print(f"[LOADER] Vision mode — {handler_cls_name} with mmproj: {clip_model_path}")
        quiet_mtmd_logging()
        chat_handler = handler_cls(clip_model_path=clip_model_path, verbose=False)

    return llama_cpp.Llama(
        model_path=model_path,
        n_ctx=32768,
        n_gpu_layers=-1,
        verbose=False,
        chat_handler=chat_handler,
        # Size sliding-window layers' KV cache to their window, not to n_ctx.
        # For Gemma 4 12B that is 480 MiB instead of 10,240 MiB, with the same
        # answers and speed (measured; see test_model_manager). Models without
        # sliding-window attention are unaffected.
        swa_full=False,
    )


def is_transformers_embedding_model(model_id: str) -> bool:
    """Check if the model ID corresponds to an EmbeddingGemma Transformers model."""
    if not model_id:
        return False
    return "embeddinggemma" in model_id.lower()


def select_embedding_dtype(device: str) -> torch.dtype:
    """
    Select the precision for loading the embedding model.

    Returns torch.bfloat16 only when device == "cuda" and torch.cuda.is_bf16_supported(),
    otherwise torch.float32.

    NEVER use float16: activations overflow fp16 and silently produce NaN/garbage vectors.
    """
    if device == "cuda" and torch.cuda.is_bf16_supported():
        return torch.bfloat16
    return torch.float32


def load_embedding_model(model_id: str, filename: str, local_dir: str) -> Any:
    """
    Load an embedding model, choosing between LlamaCpp (GGUF) and Transformers.
    """
    print(f"[EMBEDDING] Attempting to load embedding model: {model_id}")
    
    # Check if it's a Transformers model snapshot (no filename) or EmbeddingGemma
    if filename is None or is_transformers_embedding_model(model_id):
        return load_transformers_embedding_model(model_id, local_dir)
    
    # Default to LlamaCpp for GGUF models
    model_path = find_local_model(filename, local_dir)
    if not model_path:
        print(f"[EMBEDDING] Model not found locally, downloading: {model_id}/{filename}")
        model_path = download_gguf_model(model_id, filename, local_dir)
    
    print(f"[EMBEDDING] Initializing LlamaCpp for embeddings from {model_path}...")
    llm = LlamaCpp(
        model_path=model_path,
        embedding=True,  # Crucial flag for embedding generation
        n_ctx=4096,
        n_gpu_layers=-1,
        verbose=False,
    )
    
    print(f"[EMBEDDING] GGUF Embedding model loaded successfully.")
    return llm, None


def load_transformers_embedding_model(model_id: str, local_dir: str) -> Any:
    """
    Load an EmbeddingGemma 2 model using SentenceTransformer.
    """
    print(f"[EMBEDDING] Loading Transformers model: {model_id} from {local_dir}")
    
    # MPS (Metal Performance Shaders) on Apple Silicon is untested for this model
    # and CPU is the safe default. Use CUDA if available, otherwise CPU.
    if torch.cuda.is_available():
        device = "cuda"
    else:
        device = "cpu"
    print(f"[EMBEDDING] Using device: {device}")
    dtype = select_embedding_dtype(device)

    # The Makefile downloads the full repo into models/<org>/<model_name>/
    # so local_dir is already the parent, just use it directly.
    model_path = local_dir
    if not os.path.isdir(model_path):
        # Fallback to model_id for HF Hub auto-download
        model_path = model_id

    print(f"[EMBEDDING] Loading from {model_path}...")
    st_cls = SentenceTransformer
    if st_cls is None:
        try:
            from sentence_transformers import SentenceTransformer as _ST
            st_cls = _ST
        except ImportError as e:
            # The package may be present but failing to import; name the real
            # error, which transformers wraps in a generic ImportError.
            root_cause = e
            while root_cause.__cause__ is not None:
                root_cause = root_cause.__cause__
            raise RuntimeError(
                f"sentence-transformers could not be imported: {type(root_cause).__name__}: {root_cause}"
            ) from e

    model = st_cls(model_path, device=device, model_kwargs={"torch_dtype": dtype})

    # Fail loudly rather than serve noise. Check the dimension immediately after loading.
    dim = model.get_sentence_embedding_dimension()
    if dim != EMBEDDING_DIMENSION:
        raise RuntimeError(
            f"Embedding model {model_id} reported dimension {dim}, expected {EMBEDDING_DIMENSION}. "
            "Its embeddings would be incompatible or noise."
        )

    print(f"[EMBEDDING] Transformers model {model_id} loaded successfully.")
    return model, None


def generate_embeddings(
    model: Any,
    processor: Any = None,
    texts: Optional[List[str]] = None,
    images_base64: Optional[List[str]] = None,
    filename: Optional[str] = None,
    audios_base64: Optional[List[str]] = None,
    videos_base64: Optional[List[str]] = None,
    task: str = "document"
) -> List[List[float]]:
    """
    Universal embedding generator that handles both LlamaCpp and Transformers.

    Takes and returns lists, one vector per input, in order. Callers with a
    single item send a list of one — a uniform shape beats a singular and a
    plural path that can drift apart.
    """
    # Which route is taken is a property of the loaded model, not of the call.
    if hasattr(model, 'client') and hasattr(model.client, 'embed'):
        # LlamaCpp path (Text only). No multimodal support here.
        if images_base64 or audios_base64 or videos_base64:
            raise ValueError("LlamaCpp does not support multimodal embeddings (images, audios, videos) in this implementation.")
        return [generate_text_embedding(text, model, processor) for text in (texts or [])]

    # Transformers path
    return generate_transformers_multimodal_embedding(
        model=model,
        texts=texts,
        images_base64=images_base64,
        filename=filename,
        audios_base64=audios_base64,
        videos_base64=videos_base64,
        task=task,
    )


def generate_transformers_multimodal_embedding(
    model: Any,
    texts: Optional[List[str]] = None,
    images_base64: Optional[List[str]] = None,
    filename: Optional[str] = None,
    audios_base64: Optional[List[str]] = None,
    videos_base64: Optional[List[str]] = None,
    task: str = "document"
) -> List[List[float]]:
    """
    Generate embeddings using EmbeddingGemma 2 Transformers model via SentenceTransformer.

    Inputs are packed in strict modality order: texts (each prefixed with QUERY_PROMPT
    if task == 'query' else DOCUMENT_PROMPT), then images (dict {"image": PIL.Image}),
    then audios (dict {"audio": path} pointing to temporary file), then videos
    (dict {"video": path} pointing to temporary file).

    Prefixes apply to TEXT ONLY. Images, audios, and videos get no prefix.
    Temporary files created for audio/video decoding are deleted in a finally block.
    Output order strictly matches input order.

    Raises:
        ValueError: If task is not 'query' or 'document'.
        ValueError: If model outputs NaN values (guards against float16 overflow).
    """
    import tempfile
    import numpy as np

    if task not in ("query", "document"):
        raise ValueError(f"Invalid task '{task}'. Expected 'query' or 'document'.")

    temp_files: List[str] = []
    try:
        inputs: List[Any] = []

        if texts:
            prefix = QUERY_PROMPT if task == "query" else DOCUMENT_PROMPT
            inputs.extend([f"{prefix}{t}" for t in texts])

        if images_base64:
            for b64 in images_base64:
                img = decode_base64_image(b64, filename)
                inputs.append({"image": img})

        if audios_base64:
            ext = ".wav"
            if filename:
                f_ext = os.path.splitext(filename)[1].lower()
                if f_ext:
                    ext = f_ext
            for b64 in audios_base64:
                raw_b64 = b64.split(",", 1)[1] if b64.startswith("data:") else b64
                try:
                    audio_bytes = base64.b64decode(raw_b64)
                except Exception as e:
                    raise ValueError(f"Invalid base64 audio data: {e}")
                tmp = tempfile.NamedTemporaryFile(suffix=ext, delete=False)
                try:
                    tmp.write(audio_bytes)
                finally:
                    tmp.close()
                temp_files.append(tmp.name)
                inputs.append({"audio": tmp.name})

        if videos_base64:
            ext = ".mp4"
            if filename:
                f_ext = os.path.splitext(filename)[1].lower()
                if f_ext:
                    ext = f_ext
            for b64 in videos_base64:
                raw_b64 = b64.split(",", 1)[1] if b64.startswith("data:") else b64
                try:
                    video_bytes = base64.b64decode(raw_b64)
                except Exception as e:
                    raise ValueError(f"Invalid base64 video data: {e}")
                tmp = tempfile.NamedTemporaryFile(suffix=ext, delete=False)
                try:
                    tmp.write(video_bytes)
                finally:
                    tmp.close()
                temp_files.append(tmp.name)
                inputs.append({"video": tmp.name})

        if not inputs:
            return []

        embeddings = model.encode(inputs, normalize_embeddings=True, convert_to_numpy=True)
        arr = np.asarray(embeddings)

        if np.isnan(arr).any():
            raise ValueError("Model output contains NaN values. Ensure bfloat16 or float32 precision is used.")

        if arr.ndim == 1:
            arr = np.expand_dims(arr, axis=0)

        return arr.tolist()

    finally:
        for path in temp_files:
            try:
                if os.path.exists(path):
                    os.unlink(path)
            except OSError:
                pass


def generate_text_embedding(text: str, model: Any, processor: Any) -> List[float]:
    """
    Generate embeddings for text input using a loaded model.
    """
    # If using LlamaCpp directly (from LangChain's LLM), we can use the underlying client
    if hasattr(model, 'client') and hasattr(model.client, 'embed'):
        # No per-call logging here. This runs once per embedded item — a PST
        # import puts thousands through it — and echoing `text` printed the head
        # of every email's HTML body to the client's console.
        result = model.client.embed(text)
        if isinstance(result, list) and len(result) > 0:
            if isinstance(result[0], list):
                return result[0]
            elif hasattr(result[0], 'embedding'):
                return result[0].embedding
        return result
    else:
        raise ValueError("Provided model does not support LlamaCpp embedding generation correctly")


def decode_base64_image(image_base64: str, filename: Optional[str] = None) -> Image.Image:
    """
    Decode a base64 encoded image string (optionally with data URI prefix) into a PIL Image.
    If the filename indicates it is a RAW image format (e.g., .nef), decodes using rawpy.
    """
    import base64
    import io
    from PIL import Image

    if image_base64.startswith("data:"):
        image_base64 = image_base64.split(",", 1)[1]
    try:
        image_bytes = base64.b64decode(image_base64)
        
        # Check if it is a RAW image file based on extension
        if filename:
            ext = os.path.splitext(filename)[1].lower()
            if ext in ['.nef', '.cr2', '.arw', '.dng', '.orf', '.sr2']:
                import tempfile
                with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
                    tmp.write(image_bytes)
                    tmp_name = tmp.name
                try:
                    import rawpy
                    with rawpy.imread(tmp_name) as raw:
                        rgb = raw.postprocess(use_camera_wb=True, no_auto_bright=True, bright=1.0)
                        return Image.fromarray(rgb)
                finally:
                    try:
                        os.unlink(tmp_name)
                    except:
                        pass

        img = Image.open(io.BytesIO(image_bytes))
        img.load()
        return img.convert("RGB")
    except Exception as e:
        print(f"[EMBEDDING] Failed to parse image_base64: {e}")
        raise ValueError(f"Invalid image_base64 format provided: {e}")

