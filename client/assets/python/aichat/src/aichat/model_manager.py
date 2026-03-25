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
from langchain_community.llms import LlamaCpp

from .config import MAX_NEW_TOKENS, TEMPERATURE, DO_SAMPLE


def load_gemini_model() -> ChatGoogleGenerativeAI:
    """
    Initializes a connection to the Google Gemini API.

    This function creates a LangChain object for interacting with the
    Google Gemini service. It requires the GOOGLE_API_KEY environment
    variable to be set.

    Returns:
        ChatGoogleGenerativeAI: An instance of the LangChain Google AI chat model.

    Raises:
        ValueError: If the GOOGLE_API_KEY environment variable is not set.
        
    Example:
        >>> gemini_llm = load_gemini_model()
        >>> response = gemini_llm.invoke("Hello, Gemini!")
    """
    print("[LOADER] Initializing Google Gemini client.")

    api_key = os.environ.get("GOOGLE_API_KEY")
    if not api_key:
        raise ValueError("GOOGLE_API_KEY environment variable not set.")

    # Initialize the ChatGoogleGenerativeAI client
    # You can specify other parameters like temperature, top_p, etc.
    llm = ChatGoogleGenerativeAI(
        model="gemini-3.1-pro-preview",
        google_api_key=api_key,
        temperature=TEMPERATURE,
        # convert_system_message_to_human=True # Use if needed for older models
    )

    return llm


def load_local_model(model_name: str, model_path: str) -> LlamaCpp:
    """
    Load a language model from disk into a LangChain LlamaCpp object.
    
    Args:
        model_name (str): HF repo ID or display name (used for logging only)
        model_path (str): Full absolute path to the .gguf file
        
    Returns:
        LlamaCpp: Wrapped pipeline ready for text generation
        
    Raises:
        Exception: If model loading fails.

    Example:
        >>> llm = load_local_model("bartowski/gemma", "/path/to/gemma-3-4b.gguf")
        >>> response = llm.invoke("Hi!")
    """
    print(f"[LOADER] Attempting to load GGUF model: {model_name} from {model_path}")
    
    # Initialize LlamaCpp directly from the resolved path
    print(f"[LOADER] Initializing LlamaCpp from {model_path}...")
    llm = LlamaCpp(
        model_path=model_path,
        temperature=TEMPERATURE,
        max_tokens=MAX_NEW_TOKENS,
        n_ctx=4096,
        n_gpu_layers=-1, # Offload all layers to GPU (Metal on Mac)
        verbose=False,   # Disabled to clean up flutter logs
    )
    
    return llm


def load_embedding_model(model_id: str, filename: str, local_dir: str) -> Any:
    """
    Load an embedding model, choosing between LlamaCpp (GGUF) and Transformers.
    """
    print(f"[EMBEDDING] Attempting to load embedding model: {model_id}")
    
    # Check if it's the Qwen-VL or SigLIP Transformers model
    if "Qwen3-VL-Embedding" in model_id or "siglip" in model_id.lower():
        return load_transformers_embedding_model(model_id, local_dir)
    
    # Default to LlamaCpp for GGUF models
    from .utils import find_local_model, download_gguf_model
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
        trust_remote_code=True,
        dtype=torch.float16 if device != "cpu" else torch.float32
    ).to(device)
    
    processor = AutoProcessor.from_pretrained(model_path, trust_remote_code=True)
    
    print(f"[EMBEDDING] Transformers model {model_id} loaded successfully.")
    return model, processor


def generate_embedding(
    model: Any, 
    processor: Any, 
    text: Optional[str] = None, 
    image_base64: Optional[str] = None
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
    return generate_transformers_multimodal_embedding(model, processor, text, image_base64)


def _generate_siglip_embedding(
    model: Any, 
    processor: Any, 
    text: Optional[str] = None, 
    image_base64: Optional[str] = None
) -> List[float]:
    import base64
    import io
    from PIL import Image

    device = next(model.parameters()).device
    
    images = []
    if image_base64:
        if image_base64.startswith("data:image"):
            image_base64 = image_base64.split(",")[1]
        try:
            image_bytes = base64.b64decode(image_base64)
            images.append(Image.open(io.BytesIO(image_bytes)).convert("RGB"))
        except Exception as e:
            print(f"[EMBEDDING] Failed to parse image_base64: {e}")
            raise ValueError("Invalid image_base64 format provided.")
            
    texts = [text] if text else None
    
    if images and texts:
        inputs = processor(text=texts, images=images, padding="max_length", return_tensors="pt").to(device)
        with torch.no_grad():
            image_kwargs = {"pixel_values": inputs.pixel_values}
            if "pixel_attention_mask" in inputs:
                image_kwargs["attention_mask"] = inputs.pixel_attention_mask
            if "spatial_shapes" in inputs:
                image_kwargs["spatial_shapes"] = inputs.spatial_shapes
            image_features = model.get_image_features(**image_kwargs)
            text_kwargs = {"input_ids": inputs.input_ids}
            if "attention_mask" in inputs:
                text_kwargs["attention_mask"] = inputs.attention_mask
            text_features = model.get_text_features(**text_kwargs)
            image_embeds = torch.nn.functional.normalize(image_features, p=2, dim=1)
            text_embeds = torch.nn.functional.normalize(text_features, p=2, dim=1)
            embeddings = torch.nn.functional.normalize(image_embeds + text_embeds, p=2, dim=1)
    elif images:
        inputs = processor(images=images, padding="max_length", return_tensors="pt").to(device)
        with torch.no_grad():
            image_kwargs = {"pixel_values": inputs.pixel_values}
            if "pixel_attention_mask" in inputs:
                image_kwargs["attention_mask"] = inputs.pixel_attention_mask
            if "spatial_shapes" in inputs:
                image_kwargs["spatial_shapes"] = inputs.spatial_shapes
            image_features = model.get_image_features(**image_kwargs)
            embeddings = torch.nn.functional.normalize(image_features, p=2, dim=1)
    elif texts:
        inputs = processor(text=texts, padding="max_length", return_tensors="pt").to(device)
        with torch.no_grad():
            text_kwargs = {"input_ids": inputs.input_ids}
            if "attention_mask" in inputs:
                text_kwargs["attention_mask"] = inputs.attention_mask
            text_features = model.get_text_features(**text_kwargs)
            embeddings = torch.nn.functional.normalize(text_features, p=2, dim=1)
    else:
        raise ValueError("Either text or image_base64 must be provided.")
        
    return embeddings[0].tolist()


def generate_transformers_multimodal_embedding(
    model: Any, 
    processor: Any, 
    text: Optional[str] = None, 
    image_base64: Optional[str] = None
) -> List[float]:
    """
    Generate embeddings using Qwen-VL or SigLIP Transformers model.
    """
    model_type = getattr(getattr(model, 'config', object()), 'model_type', '')
    model_name = getattr(getattr(model, 'config', object()), '_name_or_path', '')
    if 'siglip' in model_type.lower() or 'siglip' in model_name.lower():
        return _generate_siglip_embedding(model, processor, text, image_base64)
        
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

