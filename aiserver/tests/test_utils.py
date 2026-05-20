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
    download_from_url,
    download_gguf_model_if_needed
)

class TestUtils:
    
    def test_get_local_path_formatting(self):
        """Test formatting of local path creation."""
        path = get_local_path("bartowski/gemma-3-4b")
        # Ensure the slash in model name is replaced by a dash
        assert path == "./bartowski-gemma-3-4b-local/"

    def test_get_local_zip_path_formatting(self):
        """Test formatting of local zip path creation."""
        path = get_local_zip_path("bartowski/gemma-3-4b")
        assert path == "./bartowski-gemma-3-4b-local.tar.gz"

    @patch('aichat.utils.os.makedirs')
    @patch('urllib.request.urlopen')
    @patch('aichat.utils.tarfile.open')
    @patch('builtins.open', new_callable=mock_open)
    def test_download_from_url_success(self, mock_file, mock_tar_open, mock_urlopen, mock_makedirs):
        """Test the download and extraction of a tar archive."""
        # Setup mock URL response
        mock_response = mock_urlopen.return_value.__enter__.return_value
        mock_response.info.return_value.get.return_value = '1024' # contentLength
        mock_response.read.side_effect = [b"chunk1", b"chunk2", b""] # End of stream
        
        # Setup mock Tar archive extractor
        mock_tar_instance = mock_tar_open.return_value.__enter__.return_value
        
        url = "http://example.com/archive.tgz"
        local_dir = "/tmp/models"
        archive_path = "/tmp/models/archive.tgz"
        extract_dir = "/tmp/models/extracted"
        
        with patch('aichat.utils.handle_local_archive') as mock_handle:
            mock_handle.return_value = True
            result = download_from_url(url, local_dir)
            
            assert result is True
            mock_urlopen.assert_called_once_with(url)


    @patch('aichat.utils.os.path.exists')
    @patch('aichat.utils.os.path.isdir')
    @patch('huggingface_hub.hf_hub_download')
    def test_download_gguf_model_if_needed_hf_download(self, mock_hf_download, mock_isdir, mock_exists):
        """Test gguf download fallback hierarchy to hit hf_hub_download."""
        # 1. Bundled - Not found
        # 2. Local intended - Not found initially
        mock_exists.side_effect = lambda p: False
        
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