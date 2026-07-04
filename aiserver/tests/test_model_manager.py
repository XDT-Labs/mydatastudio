"""
Unit tests for model loading and embedding extraction using LlamaCpp and Gemini.
"""
import pytest
import os
from unittest.mock import Mock, patch
from PIL import Image

from aichat.model_manager import (
    load_gemini_model,
    load_claude_model,
    load_openai_model,
    load_grok_model,
    load_local_model,
    load_embedding_model,
    generate_text_embedding,
    decode_base64_image
)

class TestModelManager:
    
    @patch.dict(os.environ, clear=True)
    def test_load_gemini_model_no_key(self):
        """Test Gemini model loading failure when GOOGLE_API_KEY is missing."""
        with pytest.raises(ValueError) as exc_info:
            load_gemini_model()
            
        assert "GOOGLE_API_KEY" in str(exc_info.value)
        
    @patch.dict(os.environ, {"GOOGLE_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatGoogleGenerativeAI')
    def test_load_gemini_model_success(self, mock_genai):
        """Test successful Gemini model loading."""
        mock_instance = Mock()
        mock_genai.return_value = mock_instance
        
        result = load_gemini_model()
        
        assert result == mock_instance
        mock_genai.assert_called_once_with(
            model="gemini-3.1-pro-preview",
            google_api_key="fake_key",
            temperature=0.7
        )
        
    @patch.dict(os.environ, clear=True)
    def test_load_claude_model_no_key(self):
        """Test Claude model loading failure when ANTHROPIC_API_KEY is missing."""
        with pytest.raises(ValueError) as exc_info:
            load_claude_model()

        assert "ANTHROPIC_API_KEY" in str(exc_info.value)

    @patch.dict(os.environ, {"ANTHROPIC_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatAnthropic')
    def test_load_claude_model_success(self, mock_anthropic):
        """Test successful Claude model loading."""
        mock_instance = Mock()
        mock_anthropic.return_value = mock_instance

        result = load_claude_model()

        assert result == mock_instance
        mock_anthropic.assert_called_once_with(
            model="claude-sonnet-4-5",
            api_key="fake_key",
            temperature=0.7
        )

    @patch.dict(os.environ, clear=True)
    def test_load_openai_model_no_key(self):
        """Test OpenAI model loading failure when OPENAI_API_KEY is missing."""
        with pytest.raises(ValueError) as exc_info:
            load_openai_model()

        assert "OPENAI_API_KEY" in str(exc_info.value)

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatOpenAI')
    def test_load_openai_model_success(self, mock_openai):
        """Test successful OpenAI model loading, with temperature applied for standard models."""
        mock_instance = Mock()
        mock_openai.return_value = mock_instance

        result = load_openai_model()

        assert result == mock_instance
        mock_openai.assert_called_once_with(
            model="gpt-4o",
            api_key="fake_key",
            temperature=0.7
        )

    @patch.dict(os.environ, {"OPENAI_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatOpenAI')
    def test_load_openai_model_reasoning_model_omits_temperature(self, mock_openai):
        """o-series reasoning models reject any non-default temperature."""
        mock_instance = Mock()
        mock_openai.return_value = mock_instance

        result = load_openai_model(model_id="o3")

        assert result == mock_instance
        mock_openai.assert_called_once_with(model="o3", api_key="fake_key")

    @patch.dict(os.environ, clear=True)
    def test_load_grok_model_no_key(self):
        """Test Grok model loading failure when XAI_API_KEY is missing."""
        with pytest.raises(ValueError) as exc_info:
            load_grok_model()

        assert "XAI_API_KEY" in str(exc_info.value)

    @patch.dict(os.environ, {"XAI_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatOpenAI')
    def test_load_grok_model_success(self, mock_openai):
        """Test successful Grok model loading, using OpenAI-compatible client against x.ai's base_url."""
        mock_instance = Mock()
        mock_openai.return_value = mock_instance

        result = load_grok_model()

        assert result == mock_instance
        mock_openai.assert_called_once_with(
            model="grok-3",
            api_key="fake_key",
            base_url="https://api.x.ai/v1",
            temperature=0.7
        )

    @patch('aichat.model_manager.LlamaCpp')
    def test_load_local_model_success(self, mock_llamacpp):
        """Test successful local LlamaCpp model loading."""
        mock_instance = Mock()
        mock_llamacpp.return_value = mock_instance
        
        result = load_local_model("bartowski/gemma", "/fake/path/model.gguf")
        
        assert result == mock_instance
        
        # Verify LlamaCpp initialization parameters
        init_kwargs = mock_llamacpp.call_args[1]
        assert init_kwargs["model_path"] == "/fake/path/model.gguf"
        assert init_kwargs["temperature"] == 0.7
        assert init_kwargs["max_tokens"] == 512
        assert init_kwargs["n_gpu_layers"] == -1

    @patch('aichat.model_manager.find_local_model')
    @patch('aichat.model_manager.download_gguf_model')
    @patch('aichat.model_manager.LlamaCpp')
    def test_load_embedding_model_success(self, mock_llamacpp, mock_download, mock_find_local):
        """Test successful local embedding model loading."""
        mock_find_local.return_value = None  # Force download fallback
        mock_download.return_value = "/fake/path/embed.gguf"
        mock_instance = Mock()
        mock_llamacpp.return_value = mock_instance
        
        model, processor = load_embedding_model("repo", "embed.gguf", "/tmp")
        
        assert model == mock_instance
        assert processor is None
        mock_download.assert_called_once_with("repo", "embed.gguf", "/tmp")
        
        # Verify initialization parameters (e.g. embedding=True)
        init_kwargs = mock_llamacpp.call_args[1]
        assert init_kwargs["model_path"] == "/fake/path/embed.gguf"
        assert init_kwargs["embedding"] is True
        
    def test_generate_text_embedding_success(self):
        """Test text embedding extraction from a loaded model."""
        mock_model = Mock()
        # Mocking model.client.embed() which is used by generate_text_embedding
        mock_client = Mock()
        mock_model.client = mock_client
        mock_client.embed.return_value = [0.1, 0.2, 0.3, 0.4]
        
        result = generate_text_embedding("Sample text", mock_model, None)
        
        assert result == [0.1, 0.2, 0.3, 0.4]
        mock_client.embed.assert_called_once_with("Sample text")

    def test_generate_text_embedding_failure(self):
        """Test extraction failure when client lacks embed method."""
        mock_model = object()  # Explicitly lacking .client attribute
        
        with pytest.raises(ValueError) as exc_info:
            generate_text_embedding("Sample", mock_model, None)
            
        assert "embedding generation correctly" in str(exc_info.value).lower()
        
    def test_decode_base64_image_success(self):
        """Test standard base64 decoding to PIL Image."""
        # 1x1 transparent PNG in base64
        valid_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        
        image = decode_base64_image(valid_b64)
        
        assert isinstance(image, Image.Image)
        assert image.mode == "RGB"
        assert image.size == (1, 1)
        
    def test_decode_base64_image_with_prefix(self):
        """Test decoding when string has data URI prefix."""
        prefix_b64 = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        
        image = decode_base64_image(prefix_b64)
        
        assert isinstance(image, Image.Image)
        assert image.size == (1, 1)
        
    def test_decode_base64_image_invalid(self):
        """Test decoding raises ValueError on bad string."""
        with pytest.raises(ValueError):
            decode_base64_image("not_a_valid_base64_string!!!")