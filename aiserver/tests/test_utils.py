"""
Unit tests for the utils module, specifically path generation, downloading, and extraction.
"""
import pytest
import os
import sys
from unittest.mock import patch, mock_open, MagicMock

from aichat.utils import (
    get_local_path,
    get_local_zip_path,
    download_gguf_model_if_needed,
    stream_download_snapshot,
    is_snapshot_downloaded,
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


class TestStreamDownloadSnapshot:
    """Covers the multi-file repo download path used for Transformers models
    like Qwen3-VL-Embedding-2B, which can't be fetched as a single GGUF file."""

    def test_skips_download_when_all_files_already_present(self, tmp_path):
        (tmp_path / "config.json").write_text("{}")

        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('requests.head') as mock_head, \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_files.return_value = ["config.json"]

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert len(events) == 1
        assert '"status": "complete"' in events[0]
        mock_head.assert_not_called()
        mock_get.assert_not_called()

    def test_downloads_missing_files_and_writes_them_to_disk(self, tmp_path):
        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('huggingface_hub.hf_hub_url', side_effect=lambda repo_id, filename: f"https://hf/{filename}"), \
             patch('requests.head') as mock_head, \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_files.return_value = ["config.json", "sub/tokenizer.json"]
            mock_head.return_value.headers = {'content-length': '10'}

            mock_response = MagicMock()
            mock_response.__enter__.return_value = mock_response
            mock_response.iter_content.return_value = [b'0123456789']
            mock_get.return_value = mock_response

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert any('"status": "complete"' in e for e in events)
        assert (tmp_path / "config.json").exists()
        assert (tmp_path / "sub" / "tokenizer.json").exists()

    def test_yields_error_event_on_failure_instead_of_raising(self, tmp_path):
        with patch('huggingface_hub.HfApi') as mock_api_cls:
            mock_api_cls.return_value.list_repo_files.side_effect = Exception("network down")

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert len(events) == 1
        assert '"status": "error"' in events[0]
        assert "network down" in events[0]

    def test_rejects_path_traversal_in_repo_filename(self, tmp_path):
        """model_id is caller-controlled, so a malicious/compromised repo
        returning a '../'-laden filename must not write outside local_path."""
        outside_file = tmp_path.parent / "escaped.txt"

        with patch('huggingface_hub.HfApi') as mock_api_cls:
            mock_api_cls.return_value.list_repo_files.return_value = ["../escaped.txt"]

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert len(events) == 1
        assert '"status": "error"' in events[0]
        assert not outside_file.exists()


class TestIsSnapshotDownloaded:
    """Local-only readiness check used to avoid re-downloading (or re-hitting
    HuggingFace) on every app launch once a snapshot is complete."""

    def test_false_when_directory_missing(self, tmp_path):
        assert is_snapshot_downloaded("org/model", str(tmp_path / "missing")) is False

    def test_false_when_directory_empty(self, tmp_path):
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is False

    def test_true_once_a_real_file_exists(self, tmp_path):
        (tmp_path / "config.json").write_text("{}")
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is True

    def test_ignores_hidden_files_like_ds_store(self, tmp_path):
        (tmp_path / ".DS_Store").write_text("")
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is False