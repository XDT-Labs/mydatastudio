"""
Unit tests for the start_session endpoint.

This module contains comprehensive unit tests for the start_session API route handler,
testing model loading scenarios, session management, and error conditions.
Tests use pytest with async support and mocking for dependencies.
"""
import pytest
from unittest.mock import Mock, patch, AsyncMock
from fastapi import HTTPException

# Import the functions we want to test
from aichat.routes import start_session
from aichat.models import StartSessionRequest


class TestStartSession:
    """Test suite for the start_session endpoint."""
    
    @pytest.mark.asyncio
    async def test_start_session_model_already_loaded(self):
        """Test start_session when requested model is already loaded."""
        with patch('aichat.routes.get_locks') as mock_get_locks, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id, \
             patch('aichat.routes.get_local_path') as mock_get_local_path:
            
            # Setup mocks
            model_lock = AsyncMock()
            embedding_lock = AsyncMock()
            mock_get_locks.return_value = (model_lock, embedding_lock)
            mock_get_model_id.return_value = "google/gemma-2-9b-it"
            mock_get_local_path.return_value = "/local/path"
            
            # Create request
            request = StartSessionRequest(model_name="google/gemma-2-9b-it")
            
            # Call function
            result = await start_session(request)
            
            # Assertions
            assert result["status"] == "success"
            assert "already active" in result["message"]
            assert result["model"] == "google/gemma-2-9b-it"
    
    @pytest.mark.asyncio
    async def test_start_session_download_failure(self):
        """Test start_session when model download fails."""
        with patch('aichat.routes.get_locks') as mock_get_locks, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id, \
             patch('aichat.routes.get_local_path') as mock_get_local_path, \
             patch('aichat.routes.download_gguf_model_if_needed') as mock_download:
            
            # Setup mocks
            model_lock = AsyncMock()
            embedding_lock = AsyncMock()
            mock_get_locks.return_value = (model_lock, embedding_lock)
            mock_get_model_id.return_value = None  # No model loaded
            mock_get_local_path.return_value = "/local/path"
            mock_download.return_value = False  # Download fails
            
            # Create request
            request = StartSessionRequest(model_name="test/model")
            
            # Call function and expect exception
            with pytest.raises(HTTPException) as exc_info:
                await start_session(request)
            
            assert exc_info.value.status_code == 500
            assert "Failed to download model files" in exc_info.value.detail or "Failed to load model" in exc_info.value.detail
    
    @pytest.mark.asyncio
    async def test_start_session_model_loading_failure(self):
        """Test start_session when model loading into memory fails."""
        with patch('aichat.routes.get_locks') as mock_get_locks, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id, \
             patch('aichat.routes.get_local_path') as mock_get_local_path, \
             patch('aichat.routes.download_gguf_model_if_needed') as mock_download, \
             patch('aichat.routes.load_local_model') as mock_load_model, \
             patch('aichat.routes.set_llm_instance') as mock_set_llm, \
             patch('aichat.routes.set_current_model_id') as mock_set_model_id, \
             patch('builtins.print'):
            
            # Setup mocks
            model_lock = AsyncMock()
            embedding_lock = AsyncMock()
            mock_get_locks.return_value = (model_lock, embedding_lock)
            mock_get_model_id.return_value = None
            mock_get_local_path.return_value = "/local/path"
            mock_download.return_value = True
            mock_load_model.side_effect = Exception("Out of memory")
            
            # Create request
            request = StartSessionRequest(model_name="test/model")
            
            # Call function and expect exception
            with pytest.raises(HTTPException) as exc_info:
                await start_session(request)
            
            assert exc_info.value.status_code == 500
            assert "Failed to load model test/model into memory" in exc_info.value.detail
            
            # Verify cleanup was called
            mock_set_llm.assert_called_with(None)
            mock_set_model_id.assert_called_with(None)
    
    @pytest.mark.asyncio
    async def test_start_session_success(self):
        """Test successful model loading and session start."""
        with patch('aichat.routes.get_locks') as mock_get_locks, \
             patch('aichat.routes.get_current_model_id') as mock_get_model_id, \
             patch('aichat.routes.get_local_path') as mock_get_local_path, \
             patch('aichat.routes.download_gguf_model_if_needed') as mock_download, \
             patch('aichat.routes.load_local_model') as mock_load_model, \
             patch('aichat.routes.set_llm_instance') as mock_set_llm, \
             patch('aichat.routes.set_current_model_id') as mock_set_model_id, \
             patch('builtins.print'):
            
            # Setup mocks
            model_lock = AsyncMock()
            embedding_lock = AsyncMock()
            mock_get_locks.return_value = (model_lock, embedding_lock)
            mock_get_model_id.return_value = None
            mock_get_local_path.return_value = "/local/path"
            mock_download.return_value = True
            mock_llm_instance = Mock()
            mock_load_model.return_value = mock_llm_instance
            
            # Create request
            request = StartSessionRequest(model_name="test/model")
            
            # Call function
            result = await start_session(request)
            
            # Assertions
            assert result["status"] == "success"
            assert "successfully loaded" in result["message"]
            assert result["local_path"] == "/local/path"
            
            # Verify model was set
            mock_set_llm.assert_called_with(mock_llm_instance)
            mock_set_model_id.assert_called()


if __name__ == "__main__":
    # Run tests if file is executed directly
    import pytest
    pytest.main([__file__, "-v"])