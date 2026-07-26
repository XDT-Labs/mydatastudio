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
    set_embedding_model_id,
    register_stream,
    unregister_stream,
    is_stop_requested,
    request_stop,
    active_stream_count,
    get_generation_lock,
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


class TestStopRegistry:
    """Per-generation stop flags (L2) — a stop must not leak across streams."""

    def test_unregistered_generation_is_not_stopped(self):
        assert is_stop_requested("never-registered") is False

    def test_register_then_targeted_stop(self):
        register_stream("gen-a")
        try:
            assert is_stop_requested("gen-a") is False
            request_stop("gen-a")
            assert is_stop_requested("gen-a") is True
        finally:
            unregister_stream("gen-a")

    def test_stop_is_isolated_per_generation(self):
        """Stopping one generation must not stop a concurrent one."""
        register_stream("gen-a")
        register_stream("gen-b")
        try:
            request_stop("gen-a")
            assert is_stop_requested("gen-a") is True
            assert is_stop_requested("gen-b") is False
        finally:
            unregister_stream("gen-a")
            unregister_stream("gen-b")

    def test_new_stream_does_not_clear_anothers_pending_stop(self):
        """Registering a second stream must not reset the first's stop flag."""
        register_stream("gen-a")
        request_stop("gen-a")
        register_stream("gen-b")  # would have cleared a shared global event
        try:
            assert is_stop_requested("gen-a") is True
        finally:
            unregister_stream("gen-a")
            unregister_stream("gen-b")

    def test_stop_all_when_no_id(self):
        """request_stop(None) stops every active generation (backward compat)."""
        register_stream("gen-a")
        register_stream("gen-b")
        try:
            request_stop(None)
            assert is_stop_requested("gen-a") is True
            assert is_stop_requested("gen-b") is True
        finally:
            unregister_stream("gen-a")
            unregister_stream("gen-b")

    def test_active_stream_count_tracks_registrations(self):
        """/v1/chat/stop uses this to decide whether an id-less stop request is
        unambiguous — an untargeted stop with 2+ streams would cancel the wrong
        generation, so the count has to be exact."""
        assert active_stream_count() == 0
        register_stream("gen-a")
        try:
            assert active_stream_count() == 1
            register_stream("gen-b")
            assert active_stream_count() == 2
            unregister_stream("gen-b")
            assert active_stream_count() == 1
        finally:
            unregister_stream("gen-a")
        assert active_stream_count() == 0

    def test_unregister_discards_flag(self):
        register_stream("gen-a")
        request_stop("gen-a")
        unregister_stream("gen-a")
        assert is_stop_requested("gen-a") is False


class TestGenerationLock:
    """Serialized generation (L3) — the shared model must not run two chats at once."""

    def test_generation_lock_is_singleton(self):
        assert get_generation_lock() is get_generation_lock()

    def test_generation_lock_serializes(self):
        """Two threads holding the generation lock must never overlap."""
        import threading
        import time

        lock = get_generation_lock()
        state = {"current": 0, "max": 0}
        guard = threading.Lock()

        def worker():
            with lock:
                with guard:
                    state["current"] += 1
                    state["max"] = max(state["max"], state["current"])
                time.sleep(0.02)
                with guard:
                    state["current"] -= 1

        threads = [threading.Thread(target=worker) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # If generation were not serialized, max concurrency would exceed 1.
        assert state["max"] == 1