"""
Pydantic models for request/response validation.

This module defines all the data models used for API request and response
validation using Pydantic. These models ensure type safety, automatic
validation, and generate OpenAPI documentation.
"""
from typing import Optional
from pydantic import BaseModel, Field, ConfigDict
from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE


class ChatRequest(BaseModel):
    """
    Request model for chat completion endpoints.
    
    Defines the structure for incoming chat requests, including the user's
    prompt and optional system instructions for controlling model behavior.
    
    Attributes:
        prompt (str): The user's input message or question
        system_instruction (Optional[str]): Optional system prompt to guide model behavior
        use_genui (bool): Whether to return response in GenUI JSON format
    """
    prompt: str = Field(..., description="The user's input message or question", min_length=1)
    system_instruction: Optional[str] = Field(
        None, 
        description="Optional system prompt to guide the model's behavior and response style"
    )
    use_genui: bool = Field(
        default=True,
        description="If True, wrap response in GenUI JSON format for rich UI rendering"
    )
    
    session_id: str = Field(
        ...,
        description="Unique identifier for the chat session to maintain history"
    )
    
    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "prompt": "Explain what the difference between a list and a tuple is in Python.",
                "system_instruction": "You are a concise programming tutor.",
                "use_genui": True,
                "session_id": "123e4567-e89b-12d3-a456-426614174000"
            }
        }
    )


class StartSessionRequest(BaseModel):
    """
    Request model for starting a new model session.
    
    Defines the parameters needed to load a specific model, either from
    Hugging Face Hub or from a local archive file.
    
    Attributes:
        model_name (str): Hugging Face model repository identifier
        filename (Optional[str]): Specific GGUF file name to load
        local_path (Optional[str]): Path to local model directory or archive file
    """
    model_name: str = Field(
        default=DEFAULT_LOCAL_MODEL,
        description="Hugging Face model identifier (e.g., 'bartowski/gemma-3-4b-it-GGUF')"
    )
    filename: Optional[str] = Field(
        default=DEFAULT_GGUF_FILE,
        description="The GGUF filename to use (e.g., 'gemma-3-4b-it-Q4_K_M.gguf')"
    )
    local_path: Optional[str] = Field(
        None, 
        description="Optional path to local model file directly"
    )
    
    model_config = ConfigDict(
        json_schema_extra={
            "examples": [
                {
                    "model_name": "bartowski/gemma-3-4b-it-GGUF",
                    "filename": "gemma-3-4b-it-Q4_K_M.gguf"
                }
            ]
        }
    )


class EmbeddingRequest(BaseModel):
    """
    Request model for embedding generation endpoints.
    
    Defines the structure for embedding requests, supporting either text
    or base64-encoded images (but not both simultaneously).
    
    Attributes:
        text (Optional[str]): Text content to generate embeddings for
        image_base64 (Optional[str]): Base64-encoded image data
    """
    text: Optional[str] = Field(
        None, 
        description="Text content to generate embeddings for"
    )
    image_base64: Optional[str] = Field(
        None, 
        description="Base64-encoded image data (PNG, JPEG, etc.). Supported via Transformers (Qwen-VL)."
    )

    #https://huggingface.co/Qwen/Qwen3-Embedding-8B-GGUF
    #https://huggingface.co/DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF/tree/main
    model_name: str = Field(
        default=DEFAULT_LOCAL_MODEL,
        description="Hugging Face model identifier (e.g., 'Qwen/Qwen3-Embedding-8B-GGUF')" #DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF
    )
    filename: Optional[str] = Field(
        default=DEFAULT_GGUF_FILE,
        description="The GGUF filename to use (e.g., 'Qwen3-Embedding-8B-Q4_K_M.gguf')" #Qwen.Qwen3-VL-Embedding-2B.Q4_K_M.gguf
    )
    
    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "text": "This is a sample text to generate embeddings for.",
                "model_name": "Qwen/Qwen3-Embedding-8B-GGUF",
                "filename": "Qwen3-Embedding-8B-Q4_K_M.gguf"
            }
        }
    )


class PstImportRequest(BaseModel):
    """
    Request model for PST file import.
    
    Attributes:
        file_path (str): Absolute path to the .pst file on the local machine
        output_dir (str): Directory where attachments should be extracted
    """
    file_path: str = Field(..., description="Path to the PST file on the local machine")
    output_dir: str = Field(..., description="Directory to save extracted attachments")


class ThumbnailRequest(BaseModel):
    """
    Request model for thumbnail generation.
    
    Attributes:
        file_path (str): Absolute path to the image file on the local machine
        width (int): Target width for the thumbnail
        height (int): Target height for the thumbnail
    """
    file_path: str = Field(..., description="Absolute path to the image file on the local machine")
    width: int = Field(default=320, description="Target width for the thumbnail")
    height: int = Field(default=240, description="Target height for the thumbnail")