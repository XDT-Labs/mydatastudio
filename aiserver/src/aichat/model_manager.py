"""
Model loading and management functionality.

This module handles loading and managing GGUF models via LlamaCpp and
Google Gemini API models. It provides the core functionality for both
chat and embedding models.
"""
import os
import torch
from PIL import Image
import base64
import io
from typing import Any, List, Optional
from transformers import AutoModelForImageTextToText, AutoProcessor
from qwen_vl_utils import process_vision_info

from langchain_google_genai import ChatGoogleGenerativeAI
from langchain_openai import ChatOpenAI
from langchain_anthropic import ChatAnthropic
from langchain_community.llms import LlamaCpp

from .config import MAX_NEW_TOKENS, TEMPERATURE, DO_SAMPLE
from .utils import find_local_model, download_gguf_model


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
        chat_handler = handler_cls(clip_model_path=clip_model_path, verbose=False)

    return llama_cpp.Llama(
        model_path=model_path,
        n_ctx=32768,
        n_gpu_layers=-1,
        verbose=False,
        chat_handler=chat_handler,
    )


def load_embedding_model(model_id: str, filename: str, local_dir: str) -> Any:
    """
    Load an embedding model, choosing between LlamaCpp (GGUF) and Transformers.
    """
    print(f"[EMBEDDING] Attempting to load embedding model: {model_id}")
    
    # Check if it's the Qwen-VL Transformers model
    if "VL" in model_id:
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
    Load a Qwen-VL Embedding model using Transformers.
    """
    print(f"[EMBEDDING] Loading Transformers model: {model_id} from {local_dir}")
    
    # MPS (Metal Performance Shaders) on Apple Silicon has PyTorch memory allocation
    # bugs with Qwen-VL 3D position embeddings (mrope), causing "RuntimeError: Invalid buffer size: XX GiB".
    # Use CUDA if available, otherwise CPU.
    if torch.cuda.is_available():
        device = "cuda"
    else:
        device = "cpu"
    print(f"[EMBEDDING] Using device: {device}")

    # The Makefile downloads the full repo into models/<org>/<model_name>/
    # so local_dir is already the parent, just use it directly.
    model_path = local_dir
    if not os.path.isdir(model_path):
        # Fallback to model_id for HF Hub auto-download
        model_path = model_id

    print(f"[EMBEDDING] Loading from {model_path}...")
    # AutoModel is wrong for this checkpoint and fails *silently*. Qwen3-VL
    # Embedding declares Qwen3VLForConditionalGeneration, whose state dict nests
    # the language model under `model.language_model.*`; AutoModel resolves to
    # the bare Qwen3VLModel, which expects `language_model.*`. Every one of the
    # 625 language-model tensors therefore fails to match, gets dropped, and is
    # replaced by a fresh random initialisation — so the model still loads, still
    # returns 2048 normalised floats, and every one of them is noise.
    model, loading_info = AutoModelForImageTextToText.from_pretrained(
        model_path,
        dtype=torch.float16 if device != "cpu" else torch.float32,
        output_loading_info=True,
    )
    model = model.to(device)

    # Fail loudly rather than serve noise. Randomly-initialised weights are not
    # a degraded mode: the embeddings are meaningless, they are meaningless
    # *differently* on every process launch (so vectors written by one run can
    # never be compared with another's), and nothing downstream can detect it —
    # cosine similarity over garbage still returns plausible-looking numbers.
    missing = loading_info.get("missing_keys") or []
    if missing:
        raise RuntimeError(
            f"Embedding model {model_id} loaded with {len(missing)} randomly "
            f"initialised tensors (e.g. {missing[:3]}). Its embeddings would be "
            "noise. This means the checkpoint does not match the model class."
        )

    processor = AutoProcessor.from_pretrained(model_path)

    print(f"[EMBEDDING] Transformers model {model_id} loaded successfully.")
    return model, processor


def generate_embeddings(
    model: Any,
    processor: Any,
    texts: Optional[List[str]] = None,
    images_base64: Optional[List[str]] = None,
    filename: Optional[str] = None
) -> List[List[float]]:
    """
    Universal embedding generator that handles both LlamaCpp and Transformers.

    Takes and returns lists, one vector per input, in order. Callers with a
    single item send a list of one — a uniform shape beats a singular and a
    plural path that can drift apart.
    """
    # Which route is taken is a property of the loaded model, not of the call,
    # so it was logging the same line thousands of times per import.
    if hasattr(model, 'client') and hasattr(model.client, 'embed'):
        # LlamaCpp path (Text only). No batching available here — llama.cpp's
        # embed is one string at a time — so the list is honoured by looping.
        if images_base64:
            raise ValueError("LlamaCpp does not support image embeddings in this implementation.")
        return [generate_text_embedding(text, model, processor) for text in (texts or [])]

    # Transformers path
    return generate_transformers_multimodal_embedding(model, processor, texts, images_base64, filename)


def last_token_indices(attention_mask: "torch.Tensor") -> "torch.Tensor":
    """Index of each row's final real (non-padding) token.

    This exists because the checkpoint pools with `lasttoken` — it reads one
    position out of the sequence and calls that the embedding. Taking position
    `-1` is only that token when nothing is padded, which was true while every
    call embedded exactly one item and stops being true the moment a batch
    holds two different lengths.

    Getting it wrong does not raise: a row would be handed the hidden state of
    a PAD token, producing a confident, normalized, meaningless vector for
    every item in the batch except the longest. Search results would just
    quietly get worse.

    Derived from the mask rather than from a padding-side setting, because
    nothing in this codebase sets `padding_side` — it inherits whatever the
    processor's tokenizer config happens to carry, so depending on it would be
    depending on a default we do not control. Counting from the right works
    under either convention.
    """
    # Number of trailing zeros per row: argmax on the reversed mask finds the
    # first 1 from the end. `flip` costs nothing at these sizes.
    trailing_pad = attention_mask.flip(dims=[1]).argmax(dim=1)
    return attention_mask.shape[1] - 1 - trailing_pad


def _pool_last_token(last_hidden_state: "torch.Tensor", attention_mask: "torch.Tensor") -> "torch.Tensor":
    """Last-token pooling, then L2 normalization — per the checkpoint's own
    1_Pooling/config.json ("pooling_mode": "lasttoken")."""
    indices = last_token_indices(attention_mask)
    pooled = last_hidden_state[torch.arange(last_hidden_state.shape[0]), indices]
    return torch.nn.functional.normalize(pooled, p=2, dim=1)


def generate_transformers_multimodal_embedding(
    model: Any,
    processor: Any,
    texts: Optional[List[str]] = None,
    images_base64: Optional[List[str]] = None,
    filename: Optional[str] = None
) -> List[List[float]]:
    """
    Generate embeddings using Qwen3-VL Transformers model.

    Text is embedded as a true batch — one forward pass over all of it. That is
    the whole point of the list: at ~500 tokens per chunk, per-call overhead
    (kernel launches, the processor's Python work, the HTTP round trip) costs
    more than the matmuls, so N separate calls cost far more than one call with
    N rows. Email body chunks are a uniform 2,000 characters, so they pad
    against each other with little waste.

    Images are looped rather than batched, and callers send a list of one. Two
    photos of different dimensions expand to different numbers of vision
    tokens, so batching them is a real piece of work with no demand behind it
    — one image per file, and the file corpus is not the slow part.
    """
    device = next(model.parameters()).device

    if images_base64:
        return [
            _embed_one_multimodal(model, processor, device, image_base64=image, filename=filename)
            for image in images_base64
        ]

    messages_batch = [
        [{"role": "user", "content": [{"type": "text", "text": text}]}]
        for text in (texts or [])
    ]
    prompts = [
        processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)
        for messages in messages_batch
    ]

    inputs = processor(
        text=prompts,
        images=None,
        videos=None,
        padding=True,
        return_tensors="pt"
    ).to(device)

    return _encode(model, inputs, device)


def _embed_one_multimodal(
    model: Any,
    processor: Any,
    device: Any,
    image_base64: str,
    filename: Optional[str] = None
) -> List[float]:
    """One image through the vision path, returning a single vector."""
    # Decode and validate base64 image into a loaded PIL Image
    pil_image = decode_base64_image(image_base64, filename)
    messages = [{"role": "user", "content": [{"type": "image", "image": pil_image}]}]

    # Prepare inputs using Qwen-VL utilities and processor
    image_inputs, video_inputs = process_vision_info(messages)

    # Use chat template to ensure multimodal tokens (<|image_pad|>, etc.) are correctly inserted
    prompt = processor.apply_chat_template(messages, tokenize=False, add_generation_prompt=False)

    inputs = processor(
        text=[prompt],
        images=image_inputs,
        videos=video_inputs,
        padding=True,
        return_tensors="pt"
    ).to(device)

    return _encode(model, inputs, device)[0]


def _encode(model: Any, inputs: Any, device: Any) -> List[List[float]]:
    """Run the encoder and pool, with the existing CPU fallback for device errors."""
    # `.model` rather than the model itself: the checkpoint's class is a
    # generation head, whose forward returns vocabulary logits. The embedding
    # lives one level down, in the base model's hidden states.
    encoder = model.model

    try:
        with torch.no_grad():
            outputs = encoder(**inputs)
            embeddings = _pool_last_token(outputs.last_hidden_state, inputs["attention_mask"])

        return embeddings.tolist()
    except Exception as e:
        if "buffer size" in str(e).lower() or "out of memory" in str(e).lower() or "mps" in str(e).lower():
            print(f"[EMBEDDING] Device error on {device} ({e}). Falling back to CPU...")
            cpu_device = torch.device("cpu")
            model.to(cpu_device)
            inputs_cpu = {k: (v.to(cpu_device) if isinstance(v, torch.Tensor) else v) for k, v in inputs.items()}
            with torch.no_grad():
                outputs = model.model(**inputs_cpu)
                embeddings = _pool_last_token(outputs.last_hidden_state, inputs_cpu["attention_mask"])
            return embeddings.tolist()
        raise


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

