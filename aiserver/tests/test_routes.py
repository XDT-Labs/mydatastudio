"""
Unit tests for the routes module endpoints (excluding start_session which is in its own file).
"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from fastapi import HTTPException

from aichat.routes import health_check, generate_chat_response, generate_embedding
from aichat.models import ChatRequest, EmbeddingRequest

class TestRoutes:
    
    @pytest.mark.asyncio
    async def test_health_check_no_models(self):
        """Test health check when no models are loaded."""
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
        """Test health check when models are loaded."""
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

    @pytest.mark.asyncio
    async def test_generate_chat_response_no_session(self):
        """Test chat response without an active session."""
        with patch('aichat.routes.get_llm_instance') as mock_get_llm:
            mock_get_llm.return_value = None
            
            request = ChatRequest(prompt="Hello")
            
            with pytest.raises(HTTPException) as exc_info:
                await generate_chat_response(request)
                
            assert exc_info.value.status_code == 503
            assert "No active model session" in str(exc_info.value.detail)

    @pytest.mark.asyncio
    async def test_generate_chat_response_success(self):
        """Test chat response processing correctly."""
        with patch('aichat.routes.get_llm_instance') as mock_get_llm, \
             patch('aichat.routes.get_current_model_id') as mock_get_chat_id:
            
            mock_llm = Mock()
            mock_llm.invoke.return_value = "I am an AI response   "
            mock_get_llm.return_value = mock_llm
            mock_get_chat_id.return_value = "test-model"
            
            request = ChatRequest(prompt="Hello", system_instruction="Be helpful")
            result = await generate_chat_response(request)
            
            assert result["ai_response"] == "I am an AI response"
            assert result["model_used"] == "test-model"
            assert result["user_prompt"] == "Hello"
            
            # Verify prompt formatting
            invoke_args = mock_llm.invoke.call_args[0][0]
            assert "System Instruction: Be helpful" in invoke_args
            assert "Hello<end_of_turn>" in invoke_args
            
    @pytest.mark.asyncio
    async def test_generate_embedding_validation_failure(self):
        """Test generate embedding validation."""
        _, embedding_lock = AsyncMock(), AsyncMock()
        with patch('aichat.routes.get_locks') as mock_locks:
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            
            # Neither provided
            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest())
            assert exc_info.value.status_code == 400
            
            # Both provided
            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(EmbeddingRequest(text="A", image_base64="B"))
            assert exc_info.value.status_code == 400

    @pytest.mark.asyncio
    async def test_generate_embedding_text_success(self):
        """Test text embedding generation."""
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed, \
             patch('aichat.routes.generate_text_embedding') as mock_gen_embed, \
             patch('aichat.routes.get_embedding_model_id') as mock_get_embed_id:
            
            embedding_lock = AsyncMock()
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            mock_get_embed.return_value = (Mock(), Mock())
            mock_gen_embed.return_value = [0.1, 0.2, 0.3]
            mock_get_embed_id.return_value = "embed-model"
            
            request = EmbeddingRequest(text="Hello world")
            result = await generate_embedding(request)
            
            assert result["embedding"] == [0.1, 0.2, 0.3]
            assert result["input_type"] == "text"
            assert result["model_used"] == "embed-model"
            assert result["embedding_dimension"] == 3
            mock_gen_embed.assert_called_once()
            
    @pytest.mark.asyncio
    async def test_generate_embedding_image_not_supported(self):
        """Test image embedding generation throws correct exception."""
        with patch('aichat.routes.get_locks') as mock_locks, \
             patch('aichat.routes.get_embedding_model') as mock_get_embed:
            
            embedding_lock = AsyncMock()
            mock_locks.return_value = (AsyncMock(), embedding_lock)
            mock_get_embed.return_value = (Mock(), Mock())
            
            request = EmbeddingRequest(image_base64="bad_base_64")
            with pytest.raises(HTTPException) as exc_info:
                await generate_embedding(request)
                
            assert exc_info.value.status_code == 400
            assert "Image embedding is not natively supported" in str(exc_info.value.detail)
