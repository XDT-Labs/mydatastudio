"""
Unit tests for model auto-loading in generate_chat_completion.

The /start-session endpoint has been removed. Model loading now happens
automatically inside /v1/chat/completions when the requested model differs
from the currently loaded one.
"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from fastapi import HTTPException

from aichat.routes import generate_chat_completion
from aichat.models import ChatCompletionRequest, ChatMessage


class TestChatCompletionModelLoading:

    @pytest.mark.asyncio
    async def test_model_already_loaded_skips_reload(self):
        """Does not reload when the requested model is already active."""
        mock_llm = Mock()
        mock_llm.client = Mock()
        mock_llm.client.create_chat_completion = Mock(return_value={
            "id": "chatcmpl-1", "object": "chat.completion", "created": 0,
            "model": "test-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hi"}, "finish_reason": "stop"}],
            "usage": {}
        })

        with patch('aichat.routes.get_llm_instance', return_value=mock_llm), \
             patch('aichat.routes.get_current_model_id', return_value="test-model"), \
             patch('aichat.routes.load_local_model') as mock_load:

            request = ChatCompletionRequest(
                model="test-model",
                messages=[ChatMessage(role="user", content="Hello")]
            )
            await generate_chat_completion(request)

            mock_load.assert_not_called()

    @pytest.mark.asyncio
    async def test_model_not_found_locally_returns_404(self):
        """Returns 404 when the requested model file is not on disk."""
        with patch('aichat.routes.get_llm_instance', return_value=None), \
             patch('aichat.routes.get_current_model_id', return_value=None), \
             patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.find_local_model', return_value=None), \
             patch('aichat.routes.get_local_path', return_value="/models/"):

            model_lock = AsyncMock()
            mock_locks.return_value = (model_lock, AsyncMock())

            request = ChatCompletionRequest(
                model="some/model",
                model_file="some-model.gguf",
                messages=[ChatMessage(role="user", content="Hello")]
            )

            with pytest.raises(HTTPException) as exc_info:
                await generate_chat_completion(request)

            assert exc_info.value.status_code == 404
            assert "not found locally" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_model_load_failure_returns_500(self):
        """Returns 500 when the model file exists but fails to load into memory."""
        with patch('aichat.routes.get_llm_instance', return_value=None), \
             patch('aichat.routes.get_current_model_id', return_value=None), \
             patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.find_local_model', return_value="/path/to/model.gguf"), \
             patch('aichat.routes.load_local_model', side_effect=RuntimeError("OOM")), \
             patch('aichat.routes.set_llm_instance'), \
             patch('aichat.routes.set_current_model_id'), \
             patch('aichat.routes.get_local_path', return_value="/models/"):

            model_lock = AsyncMock()
            mock_locks.return_value = (model_lock, AsyncMock())

            request = ChatCompletionRequest(
                model="some/model",
                model_file="some-model.gguf",
                messages=[ChatMessage(role="user", content="Hello")]
            )

            with pytest.raises(HTTPException) as exc_info:
                await generate_chat_completion(request)

            assert exc_info.value.status_code == 500

    @pytest.mark.asyncio
    async def test_model_switch_loads_new_model(self):
        """Loads a new model when the request specifies a different one."""
        new_mock_llm = Mock()
        new_mock_llm.client = Mock()
        new_mock_llm.client.create_chat_completion = Mock(return_value={
            "id": "chatcmpl-2", "object": "chat.completion", "created": 0,
            "model": "new-model",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "Hi"}, "finish_reason": "stop"}],
            "usage": {}
        })

        with patch('aichat.routes.get_llm_instance', return_value=new_mock_llm), \
             patch('aichat.routes.get_current_model_id', return_value="old-model"), \
             patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.find_local_model', return_value="/path/to/new.gguf"), \
             patch('aichat.routes.load_local_model', return_value=new_mock_llm) as mock_load, \
             patch('aichat.routes.set_llm_instance'), \
             patch('aichat.routes.set_current_model_id'), \
             patch('aichat.routes.get_local_path', return_value="/models/"):

            model_lock = AsyncMock()
            mock_locks.return_value = (model_lock, AsyncMock())

            request = ChatCompletionRequest(
                model="new-model",
                model_file="new-model.gguf",
                messages=[ChatMessage(role="user", content="Hello")]
            )
            await generate_chat_completion(request)

            mock_load.assert_called_once()
