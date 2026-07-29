"""
Unit tests for the utils module, specifically path generation, downloading, and extraction.
"""
import pytest
import json
import os
import sys
from unittest.mock import patch, mock_open, MagicMock

from aichat.utils import (
    get_local_path,
    get_local_zip_path,
    download_gguf_model_if_needed,
    stream_download_snapshot,
    is_snapshot_downloaded,
    resolve_data_roots,
    discover_app_support_dir,
)

class TestUtils:
    
    def test_get_local_path_formatting(self):
        """The slash in a repo id becomes a dash, under the resolved models base.

        The base is absolute and environment-dependent (see conftest, which pins
        it via AICHAT_MODELS_DIR); only the leaf name is this function's job.
        """
        path = get_local_path("bartowski/gemma-3-4b")
        assert path == os.path.join(
            os.environ["AICHAT_MODELS_DIR"], "bartowski-gemma-3-4b-local"
        )
        assert os.path.isabs(path)

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
            local_dir="/tmp/models",
            token=None,
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


def _repo_file(path, size):
    """Build a real huggingface_hub RepoFile — stream_download_snapshot
    filters entries with isinstance(), so a MagicMock won't pass the check."""
    from huggingface_hub.hf_api import RepoFile
    return RepoFile(path=path, size=size, oid="deadbeef")


def _repo_folder(path):
    """Real RepoFolder, as returned alongside RepoFile entries when
    list_repo_tree is called with recursive=True. Has no .size attribute."""
    from huggingface_hub.hf_api import RepoFolder
    return RepoFolder(path=path, oid="deadbeef")


class TestStreamDownloadSnapshot:
    """Covers the multi-file repo download path used for Transformers models
    like Qwen3-VL-Embedding-2B, which can't be fetched as a single GGUF file."""

    def test_skips_download_when_all_files_already_present_with_matching_size(self, tmp_path):
        (tmp_path / "config.json").write_text("{}")  # 2 bytes

        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_tree.return_value = [_repo_file("config.json", 2)]

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert len(events) == 1
        assert '"status": "complete"' in events[0]
        mock_get.assert_not_called()
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is True

    def test_redownloads_file_left_truncated_by_a_prior_interrupted_download(self, tmp_path):
        """A file that exists but doesn't match the repo's reported size must be
        treated as incomplete and re-fetched — otherwise a download interrupted
        mid-file leaves a corrupt file that retries can never heal."""
        (tmp_path / "model.safetensors").write_bytes(b'0123')  # repo says this should be 10 bytes

        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('huggingface_hub.hf_hub_url', side_effect=lambda repo_id, filename: f"https://hf/{filename}"), \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_tree.return_value = [_repo_file("model.safetensors", 10)]

            mock_response = MagicMock()
            mock_response.__enter__.return_value = mock_response
            mock_response.iter_content.return_value = [b'0123456789']
            mock_get.return_value = mock_response

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert any('"status": "complete"' in e for e in events)
        mock_get.assert_called_once()
        assert (tmp_path / "model.safetensors").read_bytes() == b'0123456789'

    def test_downloads_missing_files_and_writes_them_to_disk(self, tmp_path):
        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('huggingface_hub.hf_hub_url', side_effect=lambda repo_id, filename: f"https://hf/{filename}"), \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_tree.return_value = [
                _repo_file("config.json", 10),
                _repo_file("sub/tokenizer.json", 10),
            ]

            mock_response = MagicMock()
            mock_response.__enter__.return_value = mock_response
            mock_response.iter_content.return_value = [b'0123456789']
            mock_get.return_value = mock_response

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert any('"status": "complete"' in e for e in events)
        assert (tmp_path / "config.json").exists()
        assert (tmp_path / "sub" / "tokenizer.json").exists()
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is True

    def test_ignores_folder_entries_from_recursive_tree_listing(self, tmp_path):
        """list_repo_tree(recursive=True) yields RepoFolder entries alongside
        RepoFile ones; RepoFolder has no .size, so these must be filtered out
        rather than crashing the size lookup."""
        with patch('huggingface_hub.HfApi') as mock_api_cls, \
             patch('huggingface_hub.hf_hub_url', side_effect=lambda repo_id, filename: f"https://hf/{filename}"), \
             patch('requests.get') as mock_get:
            mock_api_cls.return_value.list_repo_tree.return_value = [
                _repo_folder("sub"),
                _repo_file("sub/tokenizer.json", 10),
            ]

            mock_response = MagicMock()
            mock_response.__enter__.return_value = mock_response
            mock_response.iter_content.return_value = [b'0123456789']
            mock_get.return_value = mock_response

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert any('"status": "complete"' in e for e in events)
        assert (tmp_path / "sub" / "tokenizer.json").exists()

    def test_yields_error_event_on_failure_instead_of_raising(self, tmp_path):
        with patch('huggingface_hub.HfApi') as mock_api_cls:
            mock_api_cls.return_value.list_repo_tree.side_effect = Exception("network down")

            events = list(stream_download_snapshot("org/model", str(tmp_path)))

        assert len(events) == 1
        assert '"status": "error"' in events[0]
        assert "network down" in events[0]

    def test_rejects_path_traversal_in_repo_filename(self, tmp_path):
        """model_id is caller-controlled, so a malicious/compromised repo
        returning a '../'-laden filename must not write outside local_path."""
        outside_file = tmp_path.parent / "escaped.txt"

        with patch('huggingface_hub.HfApi') as mock_api_cls:
            mock_api_cls.return_value.list_repo_tree.return_value = [_repo_file("../escaped.txt", 4)]

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

    def test_false_when_a_real_file_exists_without_the_completion_marker(self, tmp_path):
        """A non-empty directory alone isn't proof of a complete download —
        it could be the debris of a download interrupted partway through."""
        (tmp_path / "config.json").write_text("{}")
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is False

    def test_true_once_the_completion_marker_is_written(self, tmp_path):
        (tmp_path / "config.json").write_text("{}")
        (tmp_path / ".mydatastudio_download_complete").write_text("")
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is True

    def test_ignores_unrelated_hidden_files_like_ds_store(self, tmp_path):
        (tmp_path / ".DS_Store").write_text("")
        assert is_snapshot_downloaded("org/model", str(tmp_path)) is False

class TestResolveDataRoots:
    """The allow-list behind /util/import/pst and /util/thumbnail.

    Regression cover for a silent, total failure: `resolve_data_roots` read
    APP_SUPPORT_DIR directly while `_resolve_models_base` and `_get_log_dir`
    both fell back to probing the known bundle ids. Running the server from
    source (no env var) therefore produced correct model and log paths while
    every caller-supplied path failed `_assert_within_roots` — a 403 on every
    PST import, from a server that looked healthy in every other respect.
    """

    def test_app_support_dir_env_is_used_when_set(self, tmp_path, monkeypatch):
        support = tmp_path / "support"
        support.mkdir()
        monkeypatch.setenv("APP_SUPPORT_DIR", str(support))

        roots = resolve_data_roots()

        assert os.path.realpath(str(support)) in roots

    def test_app_support_dir_is_discovered_without_the_env_var(self, tmp_path, monkeypatch):
        """The dev workflow — `python main.py`, or an IDE run config — sets no
        env var. The directory must still be found, or the allow-list rejects
        the app's own data directory."""
        support = tmp_path / "com.xdtlabs.mydatastudio.dev"
        support.mkdir()
        monkeypatch.delenv("APP_SUPPORT_DIR", raising=False)
        monkeypatch.setattr(
            "aichat.utils.discover_app_support_dir", lambda: str(support)
        )

        roots = resolve_data_roots()

        assert os.path.realpath(str(support)) in roots

    def test_config_json_storage_and_database_dirs_are_allowed(self, tmp_path, monkeypatch):
        """Storage may sit on an external volume outside Application Support."""
        support = tmp_path / "support"
        support.mkdir()
        external = tmp_path / "external-volume"
        external.mkdir()
        (support / "config.json").write_text(
            json.dumps({"storage": str(external), "database": str(external)})
        )
        monkeypatch.setenv("APP_SUPPORT_DIR", str(support))

        roots = resolve_data_roots()

        assert os.path.realpath(str(external)) in roots

    def test_discover_prefers_the_env_var_over_probing(self, tmp_path, monkeypatch):
        support = tmp_path / "explicit"
        support.mkdir()
        monkeypatch.setenv("APP_SUPPORT_DIR", str(support))

        assert discover_app_support_dir() == str(support)

    def test_discover_ignores_an_env_var_pointing_nowhere(self, tmp_path, monkeypatch):
        """A stale path must fall through to probing rather than be trusted."""
        monkeypatch.setenv("APP_SUPPORT_DIR", str(tmp_path / "does-not-exist"))

        result = discover_app_support_dir()

        assert result != str(tmp_path / "does-not-exist")
