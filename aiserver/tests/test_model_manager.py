"""
Unit tests for model loading and embedding extraction using LlamaCpp and Gemini.
"""
import inspect
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
        # The default comes from load_gemini_model's own signature rather than
        # being restated here, so bumping the default model is a one-line change
        # in the source and does not silently break an unrelated assertion.
        default_model = inspect.signature(
            load_gemini_model
        ).parameters["model_id"].default
        mock_genai.assert_called_once_with(
            model=default_model,
            google_api_key="fake_key",
            temperature=0.7
        )

    @patch.dict(os.environ, {"GOOGLE_API_KEY": "fake_key"})
    @patch('aichat.model_manager.ChatGoogleGenerativeAI')
    def test_load_gemini_model_passes_explicit_model_id(self, mock_genai):
        """An explicitly requested model id reaches the client unchanged."""
        load_gemini_model(model_id="gemini-1.5-pro")

        assert mock_genai.call_args[1]["model"] == "gemini-1.5-pro"
        
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

    # load_local_model imports llama_cpp inside the function and calls
    # llama_cpp.Llama directly. Patching aichat.model_manager.LlamaCpp (the
    # langchain wrapper, used only by load_embedding_model) left the real
    # loader running, which failed on the fake path rather than testing
    # anything.
    @patch('llama_cpp.Llama')
    def test_load_local_model_success(self, mock_llamacpp):
        """Test successful local GGUF model loading."""
        mock_instance = Mock()
        mock_llamacpp.return_value = mock_instance

        result = load_local_model("bartowski/gemma", "/fake/path/model.gguf")
        
        assert result == mock_instance
        
        # Verify construction parameters. temperature/max_tokens are no longer
        # among them: they are per-generation options passed to
        # create_chat_completion, not fixed at load time.
        init_kwargs = mock_llamacpp.call_args[1]
        assert init_kwargs["model_path"] == "/fake/path/model.gguf"
        assert init_kwargs["n_gpu_layers"] == -1
        assert init_kwargs["n_ctx"] == 32768
        # Text-only unless an mmproj path is supplied.
        assert init_kwargs["chat_handler"] is None

    @patch('llama_cpp.llama_chat_format')
    @patch('llama_cpp.Llama')
    def test_load_local_model_vision_uses_chat_handler(
        self, mock_llamacpp, mock_chat_format
    ):
        """An mmproj path switches the model into vision mode.

        Without a handler the mmproj is ignored and image parts are silently
        tokenized as text, which is the failure this guards.
        """
        handler_instance = Mock()
        mock_chat_format.Gemma4ChatHandler.return_value = handler_instance

        load_local_model(
            "bartowski/gemma",
            "/fake/path/model.gguf",
            clip_model_path="/fake/path/mmproj.gguf",
        )

        assert mock_llamacpp.call_args[1]["chat_handler"] is handler_instance
        mock_chat_format.Gemma4ChatHandler.assert_called_once_with(
            clip_model_path="/fake/path/mmproj.gguf", verbose=False
        )

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

    def test_decode_base64_image_ghostscript_oserror(self):
        """Test that OSError from PIL (e.g. Ghostscript missing for EPS) is converted to ValueError."""
        valid_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        with patch("PIL.Image.open") as mock_open:
            mock_img = Mock()
            mock_img.load.side_effect = OSError("Unable to locate Ghostscript on paths")
            mock_open.return_value = mock_img
            with pytest.raises(ValueError) as exc_info:
                decode_base64_image(valid_b64)
            assert "Unable to locate Ghostscript" in str(exc_info.value)

class TestMtmdLogSilencing:
    """mtmd echoes every text chunk it tokenizes, at INFO, with the chunk's
    full contents — so one document description put 62k characters of prompt
    into the log. `verbose=False` does not reach it: the chat handler wraps its
    *init* calls in `suppress_stdout_stderr` but not `mtmd_tokenize`, and mtmd
    keeps its own logger rather than routing through `llama_log_set`.
    """

    def test_an_info_line_is_dropped(self, capsys):
        """The whole point: this is where the prompt echo arrives."""
        from aichat.model_manager import _forward_mtmd_log, _GGML_LOG_LEVEL_INFO

        _forward_mtmd_log(_GGML_LOG_LEVEL_INFO, b"add_text: <the entire prompt>")

        assert capsys.readouterr().err == ""

    def test_a_warning_still_reaches_the_log(self, capsys):
        """Silencing the echo must not silence the diagnostics. A model that
        warns about its own state is the thing worth keeping."""
        from aichat.model_manager import _forward_mtmd_log, _GGML_LOG_LEVEL_WARN

        _forward_mtmd_log(_GGML_LOG_LEVEL_WARN, b"clip: image too large\n")

        assert "clip: image too large" in capsys.readouterr().err

    def test_an_error_still_reaches_the_log(self, capsys):
        from aichat.model_manager import _forward_mtmd_log, _GGML_LOG_LEVEL_ERROR

        _forward_mtmd_log(_GGML_LOG_LEVEL_ERROR, b"failed to encode image\n")

        assert "failed to encode image" in capsys.readouterr().err

    def test_a_continuation_of_a_dropped_line_is_dropped_too(self, capsys):
        """CONT continues whatever was logged last. Forwarding it after its
        INFO parent was dropped would print orphaned fragments of the prompt —
        the same leak in a form that reads like corruption."""
        from aichat.model_manager import _forward_mtmd_log, _GGML_LOG_LEVEL_CONT

        _forward_mtmd_log(_GGML_LOG_LEVEL_CONT, b"...rest of the prompt")

        assert capsys.readouterr().err == ""

    def test_the_callback_is_held_against_collection(self, monkeypatch):
        """A ctypes trampoline that Python collects while C still holds the
        pointer is a segfault during generation, not a quiet no-op — so the
        installer must keep a reference and must not install twice."""
        import aichat.model_manager as mm

        installed = []

        class _FakeMtmd:
            def mtmd_log_set(self, cb, user_data):
                installed.append(cb)

            def mtmd_helper_log_set(self, cb, user_data):
                installed.append(cb)

        monkeypatch.setattr(mm, "_mtmd_log_sink", None)
        monkeypatch.setattr(mm, "_import_mtmd", lambda: _FakeMtmd())

        mm._silence_mtmd_logging()
        mm._silence_mtmd_logging()

        assert len(installed) == 2, "installed once, on both mtmd loggers"
        assert mm._mtmd_log_sink is not None
        assert all(cb is mm._mtmd_log_sink for cb in installed)
