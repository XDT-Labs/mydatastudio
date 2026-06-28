"""
Unit tests for route handlers.
"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from fastapi import HTTPException

from aichat.routes import health_check, generate_chat_completion, generate_embedding
from aichat.models import ChatCompletionRequest, ChatMessage, EmbeddingRequest


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
