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
from transformers import AutoModel, AutoProcessor
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
    
    device = "mps" if torch.backends.mps.is_available() else ("cuda" if torch.cuda.is_available() else "cpu")
    print(f"[EMBEDDING] Using device: {device}")

    # The Makefile downloads the full repo into models/<org>/<model_name>/
    # so local_dir is already the parent, just use it directly.
    model_path = local_dir
    if not os.path.isdir(model_path):
        # Fallback to model_id for HF Hub auto-download
        model_path = model_id

    print(f"[EMBEDDING] Loading from {model_path}...")
    model = AutoModel.from_pretrained(
        model_path,
        dtype=torch.float16 if device != "cpu" else torch.float32
    ).to(device)

    processor = AutoProcessor.from_pretrained(model_path)
    
    print(f"[EMBEDDING] Transformers model {model_id} loaded successfully.")
    return model, processor


def generate_embedding(
    model: Any, 
    processor: Any, 
    text: Optional[str] = None, 
    image_base64: Optional[str] = None,
    filename: Optional[str] = None
) -> List[float]:
    """
    Universal embedding generator that handles both LlamaCpp and Transformers.
    """
    if hasattr(model, 'client') and hasattr(model.client, 'embed'):
        # LlamaCpp path (Text only)
        print("[EMBEDDING] Route: LlamaCpp")
        if image_base64:
            raise ValueError("LlamaCpp does not support image embeddings in this implementation.")
        return generate_text_embedding(text, model, processor)
    
    # Transformers path
    print(f"[EMBEDDING] Route: Transformers (Multimodal)")
    return generate_transformers_multimodal_embedding(model, processor, text, image_base64, filename)


def generate_transformers_multimodal_embedding(
    model: Any, 
    processor: Any, 
    text: Optional[str] = None, 
    image_base64: Optional[str] = None,
    filename: Optional[str] = None
) -> List[float]:
    """
    Generate embeddings using Qwen3-VL Transformers model.
    """
    device = next(model.parameters()).device
    
    content = []
    if image_base64:
        # Normalize base64 to data URI or just use bytes
        if not image_base64.startswith("data:image"):
            image_base64 = f"data:image/jpeg;base64,{image_base64}"
        content.append({"type": "image", "image": image_base64})
    
    if text:
        content.append({"type": "text", "text": text})
    
    messages = [{"role": "user", "content": content}]
    
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
    
    with torch.no_grad():
        print(f"[EMBEDDING] Performing inference on device: {device}")
        outputs = model(**inputs)
        # Last Token Pooling ([EOS]) as per research
        # Qwen3-VL-Embedding returns the embedding in the last hidden state of the [EOS] token
        embeddings = outputs.last_hidden_state[:, -1, :]
        print(f"[EMBEDDING] Raw embedding shape: {embeddings.shape}")
        
        # Normalize the embedding
        embeddings = torch.nn.functional.normalize(embeddings, p=2, dim=1)
        print(f"[EMBEDDING] Normalized embedding head: {embeddings[0, :5].tolist()}...")
        
    return embeddings[0].tolist()


def generate_text_embedding(text: str, model: Any, processor: Any) -> List[float]:
    """
    Generate embeddings for text input using a loaded model.
    """
    # If using LlamaCpp directly (from LangChain's LLM), we can use the underlying client
    if hasattr(model, 'client') and hasattr(model.client, 'embed'):
        print(f"[EMBEDDING] Generating text embedding (LlamaCpp) for: {text[:50]}...")
        result = model.client.embed(text)
        if isinstance(result, list) and len(result) > 0:
            if isinstance(result[0], list):
                print(f"[EMBEDDING] result[0] is list, len={len(result[0])}")
                return result[0]
            elif hasattr(result[0], 'embedding'):
                print(f"[EMBEDDING] result[0] has .embedding, len={len(result[0].embedding)}")
                return result[0].embedding
        print(f"[EMBEDDING] result type: {type(result)} len={len(result)}")
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

    if image_base64.startswith("data:image"):
        image_base64 = image_base64.split(",")[1]
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

        return Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception as e:
        print(f"[EMBEDDING] Failed to parse image_base64: {e}")
        raise ValueError(f"Invalid image_base64 format provided: {e}")

