"""
Unit tests for application global state management.
"""
import pytest
import asyncio
from unittest.mock import Mock

from aichat.state import (
    get_llm_instance,
    set_llm_instance,
    get_embedding_model,
    set_embedding_model,
    get_locks,
    get_current_model_id,
    set_current_model_id,
    get_embedding_model_id,
    set_embedding_model_id
)

class TestState:
    
    def test_llm_instance_management(self):
        """Test getting and setting the LLM instance."""
        # Initial state should be None
        set_llm_instance(None)
        assert get_llm_instance() is None
        
        # Set to mock and verify
        mock_llm = Mock()
        set_llm_instance(mock_llm)
        assert get_llm_instance() == mock_llm
        
    def test_embedding_model_management(self):
        """Test getting and setting the embedding model and processor."""
        # Initial state should be None, None
        set_embedding_model(None, None)
        assert get_embedding_model() == (None, None)
        
        # Set to mocks and verify
        mock_model = Mock()
        mock_processor = Mock()
        set_embedding_model(mock_model, mock_processor)
        assert get_embedding_model() == (mock_model, mock_processor)
        
    def test_model_id_management(self):
        """Test getting and setting text and embedding model IDs."""
        set_current_model_id(None)
        assert get_current_model_id() is None
        set_current_model_id("chat_model_id")
        assert get_current_model_id() == "chat_model_id"
        
        set_embedding_model_id(None)
        assert get_embedding_model_id() is None
        set_embedding_model_id("embed_model_id")
        assert get_embedding_model_id() == "embed_model_id"
        
    def test_get_locks(self):
        """Test that get_locks returns valid asyncio locks."""
        m_lock, e_lock = get_locks()
        assert isinstance(m_lock, asyncio.Lock)
        assert isinstance(e_lock, asyncio.Lock)
        
        # Test they are singletons relative to the module
        m_lock_2, e_lock_2 = get_locks()
        assert id(m_lock) == id(m_lock_2)
        assert id(e_lock) == id(e_lock_2)