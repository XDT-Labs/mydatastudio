"""
Unit tests for route handlers.
"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from fastapi import HTTPException

from aichat.routes import (
    health_check, generate_chat_completion, generate_embedding, generate_embedding_v1, delete_model,
    download_model, check_model_status,
)
from aichat.models import (
    ChatCompletionRequest, ChatMessage, EmbeddingRequest, EmbeddingV1Request, DeleteModelRequest, DownloadModelRequest,
)


class TestHealthCheck:

    @pytest.mark.asyncio
    async def test_health_check_no_models(self):
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.get_current_model_id') as mock_get_chat_id, \
             patch('aichat.routes.get_llm_instance') as mock_get_llm, \
             patch('aichat.routes.get_embedding_model_id') as mock_get_embed_id:

            model_lock = AsyncMock()
            model_lock.locked = Mock(return_value=False)
            embedding_lock = AsyncMock()
            embedding_lock.locked = Mock(return_value=False)
            mock_locks.return_value = (model_lock, embedding_lock)
            mock_get_embed.return_value = (None, None)
            mock_get_llm.return_value = None

            result = await health_check()

            assert result["status"] == "online"
            assert result["chat_model_loaded"] is False
            assert result["embedding_model_loaded"] is False
            assert result["is_loading"] is False

    @pytest.mark.asyncio
    async def test_health_check_with_models(self):
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.get_current_model_id') as mock_get_chat_id, \
             patch('aichat.routes.get_llm_instance') as mock_get_llm, \
             patch('aichat.routes.get_embedding_model_id') as mock_get_embed_id:

            model_lock = AsyncMock()
            model_lock.locked = Mock(return_value=False)
            embedding_lock = AsyncMock()
            embedding_lock.locked = Mock(return_value=False)
            mock_locks.return_value = (model_lock, embedding_lock)
            mock_get_embed.return_value = (Mock(), Mock())
            mock_get_llm.return_value = Mock()
            mock_get_chat_id.return_value = "chat-model-id"
            mock_get_embed_id.return_value = "embed-model-id"

            result = await health_check()

            assert result["status"] == "online"
            assert result["chat_model_loaded"] is True
            assert result["current_chat_model"] == "chat-model-id"
            assert result["embedding_model_loaded"] is True
            assert result["current_embedding_model"] == "embed-model-id"


class TestChatCompletion:

    @pytest.mark.asyncio
    async def test_chat_completion_no_model_loaded(self):
        """Returns 503 when no model is loaded and no local file found."""
        with patch('aichat.routes.get_llm_instance') as mock_get_llm, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id, \
             patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.find_local_model') as mock_find:

            mock_get_llm.return_value = None
            mock_get_model_id.return_value = None
            model_lock = AsyncMock()
            mock_locks.return_value = (model_lock, AsyncMock())
            mock_find.return_value = None  # model file not found locally

            request = ChatCompletionRequest(
                messages=[ChatMessage(role="user", content="Hello")]
            )

            with pytest.raises(HTTPException) as exc_info:
                await generate_chat_completion(request)

            assert exc_info.value.status_code == 404
            assert "not found locally" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    @patch('aichat.routes.model_registry.lookup')
    @patch('aichat.routes._handle_gemini_request')
    async def test_chat_completion_gemini_fallback(self, mock_handle_gemini, mock_lookup):
        """If model is not found in the DB (None) but starts with 'gemini', it treats it as Gemini."""
        mock_lookup.return_value = None
        mock_handle_gemini.return_value = {"choices": [{"message": {"content": "Gemini response"}}]}

        request = ChatCompletionRequest(
            model="gemini-3.5-flash",
            messages=[ChatMessage(role="user", content="Hi")]
        )

        result = await generate_chat_completion(request)

        mock_handle_gemini.assert_called_once_with(request)
        assert result["choices"][0]["message"]["content"] == "Gemini response"

    @pytest.mark.asyncio
    @patch('aichat.routes.model_registry.lookup')
    @patch('aichat.routes._handle_claude_request')
    async def test_chat_completion_claude_via_db_group(self, mock_handle_claude, mock_lookup):
        """A model registered with group='claude' is routed to the Claude handler."""
        mock_lookup.return_value = {"group": "claude"}
        mock_handle_claude.return_value = {"choices": [{"message": {"content": "Claude response"}}]}

        request = ChatCompletionRequest(
            model="claude-sonnet-4-5",
            messages=[ChatMessage(role="user", content="Hi")]
        )

        result = await generate_chat_completion(request)

        mock_handle_claude.assert_called_once_with(request)
        assert result["choices"][0]["message"]["content"] == "Claude response"

    @pytest.mark.asyncio
    @patch('aichat.routes.model_registry.lookup')
    @patch('aichat.routes._handle_openai_request')
    async def test_chat_completion_openai_fallback(self, mock_handle_openai, mock_lookup):
        """If model is not found in the DB (None) but starts with 'gpt', it treats it as OpenAI."""
        mock_lookup.return_value = None
        mock_handle_openai.return_value = {"choices": [{"message": {"content": "OpenAI response"}}]}

        request = ChatCompletionRequest(
            model="gpt-4o",
            messages=[ChatMessage(role="user", content="Hi")]
        )

        result = await generate_chat_completion(request)

        mock_handle_openai.assert_called_once_with(request)
        assert result["choices"][0]["message"]["content"] == "OpenAI response"

    @pytest.mark.asyncio
    @patch('aichat.routes.model_registry.lookup')
    @patch('aichat.routes._handle_grok_request')
    async def test_chat_completion_grok_fallback(self, mock_handle_grok, mock_lookup):
        """If model is not found in the DB (None) but starts with 'grok', it treats it as Grok."""
        mock_lookup.return_value = None
        mock_handle_grok.return_value = {"choices": [{"message": {"content": "Grok response"}}]}

        request = ChatCompletionRequest(
            model="grok-3",
            messages=[ChatMessage(role="user", content="Hi")]
        )

        result = await generate_chat_completion(request)

        mock_handle_grok.assert_called_once_with(request)
        assert result["choices"][0]["message"]["content"] == "Grok response"

    @pytest.mark.asyncio
    async def test_chat_completion_llama_cpp_path(self):
        """Uses llama_cpp's create_chat_completion when available."""
        mock_llm = Mock()
        mock_llm.client = Mock()
        mock_llm.client.create_chat_completion = Mock(return_value={
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 1234567890,
            "model": "old-model-name",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hi!"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 5, "completion_tokens": 3, "total_tokens": 8},
        })

        with patch('aichat.routes.get_llm_instance') as mock_get_llm, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id:

            mock_get_llm.return_value = mock_llm
            mock_get_model_id.return_value = "bartowski/gemma-3-4b-it-GGUF"

            request = ChatCompletionRequest(
                model="bartowski/gemma-3-4b-it-GGUF",
                messages=[
                    ChatMessage(role="system", content="Be helpful."),
                    ChatMessage(role="user", content="Hello"),
                ]
            )

            result = await generate_chat_completion(request)

            assert result["choices"][0]["message"]["content"] == "Hi!"
            assert result["model"] == "bartowski/gemma-3-4b-it-GGUF"
            mock_llm.client.create_chat_completion.assert_called_once()
            call_messages = mock_llm.client.create_chat_completion.call_args[1]["messages"]
            assert call_messages[0]["role"] == "system"
            assert call_messages[1]["role"] == "user"

    @pytest.mark.asyncio
    async def test_chat_completion_passes_temperature_and_max_tokens(self):
        """Forwards temperature and max_tokens to create_chat_completion."""
        mock_llm = Mock()
        mock_llm.client = Mock()
        mock_llm.client.create_chat_completion = Mock(return_value={
            "id": "chatcmpl-test", "object": "chat.completion", "created": 0,
            "model": "test", "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
            "usage": {}
        })

        with patch('aichat.routes.get_llm_instance', return_value=mock_llm), \
             patch('aichat.routes.get_current_model_id', return_value="test-model"):

            request = ChatCompletionRequest(
                model="test-model",
                messages=[ChatMessage(role="user", content="Hi")],
                temperature=0.5,
                max_tokens=100,
            )
            await generate_chat_completion(request)

            kwargs = mock_llm.client.create_chat_completion.call_args[1]
            assert kwargs["temperature"] == 0.5
            assert kwargs["max_tokens"] == 100


class TestMultimodalEmbedding:

    @pytest.mark.asyncio
    async def test_generate_embedding_validation_neither(self):
        _, embedding_lock = AsyncMock(), AsyncMock()
        with patch('aichat.routes.get_locks') as mock_locks:
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest())
            assert exc_info.value.status_code == 400

    @pytest.mark.asyncio
    async def test_generate_embedding_validation_both(self):
        with patch('aichat.routes.get_locks') as mock_locks:
            mock_locks.return_value = (AsyncMock(), AsyncMock())
            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest(text="A", image_base64="B"))
            assert exc_info.value.status_code == 400

    @pytest.mark.asyncio
    async def test_generate_embedding_text_success(self):
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.gen_emb_fn') as mock_gen_embed, \
             patch('aichat.routes.get_embedding_model_id') as mock_get_embed_id:

            embedding_lock = AsyncMock()
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            mock_get_embed.return_value = (Mock(), Mock())
            mock_gen_embed.return_value = [0.1, 0.2, 0.3]
            mock_get_embed_id.return_value = "embed-model"

            result = await generate_embedding(EmbeddingRequest(text="Hello world"))

            assert result["embedding"] == [0.1, 0.2, 0.3]
            assert result["input_type"] == "text"
            assert result["model_used"] == "embed-model"
            assert result["embedding_dimension"] == 3

    @pytest.mark.asyncio
    async def test_generate_embedding_image_llamacpp_raises(self):
        """LlamaCpp image embeddings raise a 400 (ValueError from model_manager)."""
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.gen_emb_fn') as mock_gen_embed:

            embedding_lock = AsyncMock()
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            mock_get_embed.return_value = (Mock(), Mock())
            mock_gen_embed.side_effect = ValueError("LlamaCpp does not support image embeddings in this implementation.")

            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest(image_base64="bad_base64"))

            assert exc_info.value.status_code == 400
            assert "LlamaCpp does not support image embeddings" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_generate_embedding_rejects_when_model_not_downloaded(self):
        """Without this guard, an unloaded model falls through to
        load_embedding_model() -> Transformers' from_pretrained(model_id),
        which silently kicks off its own blocking HF download from inside
        the request instead of failing fast."""
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.load_embedding_model') as mock_load, \
             patch('aichat.routes._embedding_model_downloaded', return_value=False) as mock_downloaded:

            mock_locks.return_value = (AsyncMock(), AsyncMock())
            mock_get_embed.return_value = (None, None)

            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest(text="hi", model_name="Qwen/Qwen3-VL-Embedding-2B"))

            assert exc_info.value.status_code == 503
            mock_downloaded.assert_called_once()
            mock_load.assert_not_called()

    @pytest.mark.asyncio
    async def test_generate_embedding_v1_rejects_when_model_not_downloaded(self):
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.load_embedding_model') as mock_load, \
             patch('aichat.routes._embedding_model_downloaded', return_value=False) as mock_downloaded:

            mock_locks.return_value = (AsyncMock(), AsyncMock())
            mock_get_embed.return_value = (None, None)

            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding_v1(EmbeddingV1Request(input="hi", model="bartowski/gemma-3-4b-it-GGUF"))

            assert exc_info.value.status_code == 503
            mock_downloaded.assert_called_once()
            mock_load.assert_not_called()


class TestEmbeddingModelDownloaded:
    """_embedding_model_downloaded() mirrors load_embedding_model()'s own
    routing: VL models are Transformers snapshots, everything else is a
    single GGUF file."""

    def test_vl_model_checks_snapshot(self):
        from aichat.routes import _embedding_model_downloaded

        # 1. Uppercase 'VL', filename is None
        with patch('aichat.routes.get_local_path', return_value="/tmp/qwen-local"), \
             patch('aichat.routes.is_snapshot_downloaded', return_value=True) as mock_snapshot, \
             patch('aichat.routes.find_local_model') as mock_find:
            assert _embedding_model_downloaded("Qwen/Qwen3-VL-Embedding-2B", None) is True
            mock_snapshot.assert_called_once_with("Qwen/Qwen3-VL-Embedding-2B", "/tmp/qwen-local")
            mock_find.assert_not_called()

        # 2. Lowercase 'vl', filename is provided
        with patch('aichat.routes.get_local_path', return_value="/tmp/qwen-local"), \
             patch('aichat.routes.is_snapshot_downloaded', return_value=True) as mock_snapshot, \
             patch('aichat.routes.find_local_model') as mock_find:
            assert _embedding_model_downloaded("qwen/qwen3-vl-embedding-2b", "dummy.gguf") is True
            mock_snapshot.assert_called_once_with("qwen/qwen3-vl-embedding-2b", "/tmp/qwen-local")
            mock_find.assert_not_called()

        # 3. No 'vl', but filename is None (Transformers model check)
        with patch('aichat.routes.get_local_path', return_value="/tmp/some-local"), \
             patch('aichat.routes.is_snapshot_downloaded', return_value=True) as mock_snapshot, \
             patch('aichat.routes.find_local_model') as mock_find:
            assert _embedding_model_downloaded("some-transformers-model", None) is True
            mock_snapshot.assert_called_once_with("some-transformers-model", "/tmp/some-local")
            mock_find.assert_not_called()

    def test_gguf_model_checks_single_file(self):
        from aichat.routes import _embedding_model_downloaded

        with patch('aichat.routes.get_local_path', return_value="/tmp/gguf-local"), \
             patch('aichat.routes.find_local_model', return_value="/tmp/gguf-local/model.gguf") as mock_find, \
             patch('aichat.routes.is_snapshot_downloaded') as mock_snapshot:
            assert _embedding_model_downloaded("bartowski/gemma-3-4b-it-GGUF", "model.gguf") is True

        mock_find.assert_called_once_with("model.gguf", "/tmp/gguf-local")
        mock_snapshot.assert_not_called()


class TestDeleteModel:

    @pytest.mark.asyncio
    async def test_delete_model_in_root_does_not_delete_root(self, tmp_path):
        import os
        models_dir = str(tmp_path / "models")
        os.makedirs(models_dir, exist_ok=True)
        
        # Place a model directly in the root of models_dir
        model_file = tmp_path / "models" / "model.gguf"
        model_file.write_text("dummy model content")
        
        request = DeleteModelRequest(model_path=str(model_file))
        
        with patch.dict(os.environ, {"AICHAT_MODELS_DIR": models_dir}):
            result = await delete_model(request)
            
        assert result["status"] == "success"
        # The file itself must be deleted
        assert not model_file.exists()
        # The root models directory MUST NOT be deleted
        assert os.path.exists(models_dir)

    @pytest.mark.asyncio
    async def test_delete_model_in_subdir_deletes_empty_subdir(self, tmp_path):
        import os
        models_dir = str(tmp_path / "models")
        os.makedirs(models_dir, exist_ok=True)
        
        # Place a model in a subdirectory under models_dir
        subdir = tmp_path / "models" / "some-model-repo"
        subdir.mkdir()
        model_file = subdir / "model.gguf"
        model_file.write_text("dummy model content")
        
        request = DeleteModelRequest(model_path=str(model_file))
        
        with patch.dict(os.environ, {"AICHAT_MODELS_DIR": models_dir}):
            result = await delete_model(request)
            
        assert result["status"] == "success"
        # The file itself must be deleted
        assert not model_file.exists()
        # The subdirectory (parent) should be deleted since it has no remaining files
        assert not subdir.exists()
        # The root models directory MUST NOT be deleted
        assert os.path.exists(models_dir)


class TestDownloadModel:
    """A null `filename` means "download the whole repo snapshot" (used for
    multi-file Transformers models like Qwen3-VL-Embedding-2B) instead of a
    single GGUF file."""

    @pytest.mark.asyncio
    async def test_null_filename_routes_to_snapshot_download(self):
        request = DownloadModelRequest(model_name="Qwen/Qwen3-VL-Embedding-2B", filename=None)

        with patch('aichat.routes.get_local_path', return_value="/tmp/qwen-local"), \
             patch('aichat.routes.stream_download_snapshot') as mock_stream_snapshot, \
             patch('aichat.routes.stream_download_gguf') as mock_stream_gguf:
            mock_stream_snapshot.return_value = iter([])

            await download_model(request)

        mock_stream_snapshot.assert_called_once_with("Qwen/Qwen3-VL-Embedding-2B", "/tmp/qwen-local", hf_token=None)
        mock_stream_gguf.assert_not_called()

    @pytest.mark.asyncio
    async def test_filename_set_still_routes_to_single_file_download(self):
        request = DownloadModelRequest(model_name="ggml-org/gemma-4-12B-it-GGUF", filename="gemma-4-12B-it-Q4_K_M.gguf")

        with patch('aichat.routes.get_local_path', return_value="/tmp/gemma-local"), \
             patch('aichat.routes.find_local_model', return_value=None), \
             patch('aichat.routes.stream_download_snapshot') as mock_stream_snapshot, \
             patch('aichat.routes.stream_download_gguf') as mock_stream_gguf:
            mock_stream_gguf.return_value = iter([])

            await download_model(request)

        mock_stream_gguf.assert_called_once()
        mock_stream_snapshot.assert_not_called()


class TestCheckModelStatus:
    """Local-disk-only readiness check the client polls at startup before
    deciding whether to kick off a download."""

    @pytest.mark.asyncio
    async def test_snapshot_mode_reports_downloaded(self):
        request = DownloadModelRequest(model_name="Qwen/Qwen3-VL-Embedding-2B", filename=None)

        with patch('aichat.routes.get_local_path', return_value="/tmp/qwen-local"), \
             patch('aichat.routes.is_snapshot_downloaded', return_value=True):
            result = await check_model_status(request)

        assert result == {"exists": True, "model_path": "/tmp/qwen-local"}

    @pytest.mark.asyncio
    async def test_snapshot_mode_reports_not_downloaded(self):
        request = DownloadModelRequest(model_name="Qwen/Qwen3-VL-Embedding-2B", filename=None)

        with patch('aichat.routes.get_local_path', return_value="/tmp/qwen-local"), \
             patch('aichat.routes.is_snapshot_downloaded', return_value=False):
            result = await check_model_status(request)

        assert result == {"exists": False, "model_path": None}

    @pytest.mark.asyncio
    async def test_single_file_mode_delegates_to_find_local_model(self):
        request = DownloadModelRequest(model_name="ggml-org/gemma-4-12B-it-GGUF", filename="gemma-4-12B-it-Q4_K_M.gguf")

        with patch('aichat.routes.get_local_path', return_value="/tmp/gemma-local"), \
             patch('aichat.routes.find_local_model', return_value="/tmp/gemma-local/gemma-4-12B-it-Q4_K_M.gguf"):
            result = await check_model_status(request)

        assert result == {"exists": True, "model_path": "/tmp/gemma-local/gemma-4-12B-it-Q4_K_M.gguf"}

