import pytest
import os
from aichat.utils import get_local_path, get_local_zip_path
from aichat.model_manager import load_embedding_model

def test_get_local_path_with_none():
    """Test get_local_path handles None model_id gracefully."""
    path = get_local_path(None)
    assert "unknown" in path
    assert path.startswith("./models/")

def test_get_local_zip_path_with_none():
    """Test get_local_zip_path handles None model_id gracefully."""
    path = get_local_zip_path(None)
    assert "unknown" in path
    assert path.startswith("./models/")
    assert path.endswith("-local.tar.gz")

def test_load_embedding_model_with_none_filename():
    """Test load_embedding_model handles None filename during multimodal detection."""
    # We mock find_local_model to simulate that no mmproj is found
    # and to avoid actual file system checks or downloads.
    from unittest.mock import patch
    
    with patch('aichat.utils.find_local_model') as mock_find, \
         patch('aichat.model_manager.LlamaCpp') as mock_llamacpp, \
         patch('aichat.model_manager.load_transformers_embedding_model') as mock_trans:
        
        mock_find.return_value = "/fake/path/model.gguf"
        mock_llamacpp.return_value = ("mock_llm", "mock_clip")
        mock_trans.return_value = ("mock_model", "mock_processor")
        
        # This used to crash if "VL" was in model_id but filename was None
        model, clip_path = load_embedding_model(
            model_id="Qwen2-VL-7B",
            filename=None,
            local_dir="/tmp"
        )
        
        assert model == "mock_model"
        assert clip_path == "mock_processor"
