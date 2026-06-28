"""
Pydantic models for request/response validation.
"""
from typing import Optional, List
from pydantic import BaseModel, Field, ConfigDict
from .config import DEFAULT_LOCAL_MODEL, DEFAULT_GGUF_FILE, DEFAULT_MODEL_ALIAS


# ── OpenAI-compatible: /v1/chat/completions ──────────────────────────────────

class ChatMessage(BaseModel):
    role: str = Field(..., description="Message role: 'system', 'user', or 'assistant'")
    content: str = Field(..., description="Message content")


class ChatCompletionRequest(BaseModel):
    model: str = Field(
        default=DEFAULT_MODEL_ALIAS,
        description="Model alias (e.g. 'gemma3:4b') or raw HF repo ID"
    )
    messages: List[ChatMessage] = Field(..., description="Conversation history in OpenAI format")
    temperature: Optional[float] = Field(None, description="Sampling temperature")
    max_tokens: Optional[int] = Field(None, description="Maximum tokens to generate")

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "model": "gemma3:4b",
                "messages": [
                    {"role": "system", "content": "You are a helpful assistant."},
                    {"role": "user", "content": "What is 2+2?"}
                ]
            }
        }
    )


# ── OpenAI-compatible: /v1/embeddings ────────────────────────────────────────

class EmbeddingV1Request(BaseModel):
    input: str = Field(..., description="Text to embed")
    model: str = Field(default=DEFAULT_MODEL_ALIAS, description="Model alias (e.g. 'gemma3:4b')")


# ── Util endpoint models (/util/*) ───────────────────────────────────────────

class EmbeddingRequest(BaseModel):
    """Multimodal embedding (text or image). Used by /util/embedding."""
    text: Optional[str] = Field(None, description="Text content to embed")
    image_base64: Optional[str] = Field(None, description="Base64-encoded image data")
    model_name: str = Field(
        default=DEFAULT_LOCAL_MODEL,
        description="Hugging Face model identifier"
    )
    filename: Optional[str] = Field(
        default=DEFAULT_GGUF_FILE,
        description="GGUF filename to use"
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "image_base64": "iVBORw0KGgo...",
                "model_name": "google/siglip2-so400m-patch16-naflex"
            }
        }
    )


class DownloadModelRequest(BaseModel):
    """Request to download a GGUF model from Hugging Face."""
    model_name: str = Field(
        default=DEFAULT_LOCAL_MODEL,
        description="Hugging Face model identifier (e.g., 'bartowski/gemma-3-4b-it-GGUF')"
    )
    filename: Optional[str] = Field(
        default=DEFAULT_GGUF_FILE,
        description="GGUF filename to download"
    )


class ThumbnailRequest(BaseModel):
    """Request to generate a thumbnail for an image file."""
    file_path: str = Field(..., description="Absolute path to the image file")
    width: int = Field(default=320, description="Target width")
    height: int = Field(default=240, description="Target height")


class PstImportRequest(BaseModel):
    """Request to import and parse an Outlook PST file."""
    file_path: str = Field(..., description="Path to the PST file")
    output_dir: str = Field(..., description="Directory to save extracted attachments")
