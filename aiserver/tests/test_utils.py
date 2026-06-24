"""
Unit tests for the utils module, specifically path generation, downloading, and extraction.
"""
import pytest
import os
import sys
from unittest.mock import patch, mock_open

from aichat.utils import (
    get_local_path,
    get_local_zip_path,
    download_gguf_model_if_needed
)

class TestUtils:
    
    def test_get_local_path_formatting(self):
        """Test formatting of local path creation."""
        path = get_local_path("bartowski/gemma-3-4b")
        # Ensure the slash in model name is replaced by a dash
        assert path == "./models/bartowski-gemma-3-4b-local/"

    def test_get_local_zip_path_formatting(self):
        """Test formatting of local zip path creation."""
        path = get_local_zip_path("bartowski/gemma-3-4b")
        assert path == "./models/bartowski-gemma-3-4b-local.tar.gz"


    @patch('aichat.utils.os.makedirs')
    @patch('aichat.utils.os.path.exists')
    @patch('aichat.utils.os.path.isdir')
    @patch('huggingface_hub.hf_hub_download')
    def test_download_gguf_model_if_needed_hf_download(self, mock_hf_download, mock_isdir, mock_exists, mock_makedirs):
        """Test gguf download fallback hierarchy to hit hf_hub_download."""
        # 1. Bundled - Not found
        # 2. Local intended - Not found initially
        mock_exists.side_effect = lambda p: False
        mock_isdir.return_value = False
        
        mock_hf_download.return_value = "/tmp/models/gemma.gguf"
        
        result = download_gguf_model_if_needed("bartowski/gemma", "gemma.gguf", "/tmp/models")
        
        assert result == "/tmp/models/gemma.gguf"
        mock_hf_download.assert_called_once_with(
            repo_id="bartowski/gemma",
            filename="gemma.gguf",
            local_dir="/tmp/models"
        )

    @patch('aichat.utils.os.path.exists')
    @patch('aichat.utils.os.path.isdir')
    @patch('huggingface_hub.hf_hub_download')
    def test_download_gguf_model_if_needed_bundled(self, mock_hf_download, mock_isdir, mock_exists):
        """Test gguf loading from bundled sys._MEIPASS location."""
        # Set up Pyinstaller flags dynamically for the test run using patch
        with patch.object(sys, 'frozen', True, create=True), \
             patch.object(sys, '_MEIPASS', '/mock_mei_pass', create=True):
            
            # 1. Bundled - YES IT EXISTS
            def exists_side_effect(path):
                if "/mock_mei_pass" in path:
                    return True
                return False
                
            mock_exists.side_effect = exists_side_effect
            mock_isdir.return_value = True
            
            result = download_gguf_model_if_needed("repo", "file.gguf", "/tmp")
            
            assert result == "/mock_mei_pass/models/file.gguf"
            mock_hf_download.assert_not_called()

    @patch('aichat.utils.os.path.exists')
    @patch('huggingface_hub.hf_hub_download')
    def test_download_gguf_model_if_needed_local_existing(self, mock_hf_download, mock_exists):
        """Test gguf loading from local directory when already downloaded."""
        def exists_side_effect(path):
            # Bundled does not exist
            if getattr(sys, '_MEIPASS', None) and getattr(sys, '_MEIPASS') in path:
                return False
            # Check for the local intended path
            if path == "/tmp/file.gguf":
                return True
            return False
            
        mock_exists.side_effect = exists_side_effect
        
        result = download_gguf_model_if_needed("repo", "file.gguf", "/tmp")
        
        assert result == "/tmp/file.gguf"
        mock_hf_download.assert_not_called()