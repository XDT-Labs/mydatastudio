"""
Unit tests for EmbeddingGemma 2 SentenceTransformer-based embedding model loading and generation.
"""
import builtins
import os
import pytest
import torch
import numpy as np
from unittest.mock import Mock, patch
from PIL import Image

from aichat.model_manager import (
    _root_cause,
    select_embedding_dtype,
    is_transformers_embedding_model,
    load_transformers_embedding_model,
    generate_transformers_multimodal_embedding,
    generate_embeddings,
    QUERY_PROMPT,
    DOCUMENT_PROMPT,
    EMBEDDING_DIMENSION,
)

# 1x1 transparent PNG base64 for image testing
VALID_PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
# Base64 encoded dummy bytes for audio/video testing
DUMMY_AUDIO_B64 = "UklGRiQAAABXQVZFZm10IBAAAAABAAEAQB8AAEAfAAABAAgAZGF0YQAAAAA="
DUMMY_VIDEO_B64 = "AAAAGGZ0eXBtcDQyAAAAAG1wNDJpc29t"


class TestSelectEmbeddingDtype:
    """Precision selection rules for EmbeddingGemma 2:
    Only bfloat16 on CUDA with bf16 hardware support; otherwise float32.
    float16 is NEVER returned because activations overflow fp16.
    """

    def test_cpu_always_float32(self):
        with patch.object(torch.cuda, "is_bf16_supported", return_value=True):
            dtype = select_embedding_dtype("cpu")
            assert dtype == torch.float32
            assert dtype != torch.float16

    def test_cuda_with_bf16_support_returns_bfloat16(self):
        with patch.object(torch.cuda, "is_bf16_supported", return_value=True):
            dtype = select_embedding_dtype("cuda")
            assert dtype == torch.bfloat16
            assert dtype != torch.float16

    def test_cuda_without_bf16_support_returns_float32(self):
        with patch.object(torch.cuda, "is_bf16_supported", return_value=False):
            dtype = select_embedding_dtype("cuda")
            assert dtype == torch.float32
            assert dtype != torch.float16


class TestIsTransformersEmbeddingModel:
    """Routing helper identifying EmbeddingGemma Transformers models vs GGUF models."""

    def test_identifies_embeddinggemma_case_insensitively(self):
        assert is_transformers_embedding_model("google/embeddinggemma-2") is True
        assert is_transformers_embedding_model("google/EmbeddingGemma-2") is True
        assert is_transformers_embedding_model("GOOGLE/EMBEDDINGGEMMA-2") is True

    def test_rejects_gguf_and_qwen_models(self):
        assert is_transformers_embedding_model("bartowski/gemma-3-4b-it-GGUF") is False
        assert is_transformers_embedding_model("Qwen/Qwen3-VL-Embedding-2B") is False
        assert is_transformers_embedding_model("mradermacher/gme-Qwen2-VL-2B-Instruct-GGUF") is False
        assert is_transformers_embedding_model("") is False
        assert is_transformers_embedding_model(None) is False


class TestLoadTransformersEmbeddingModel:
    """Loading EmbeddingGemma 2 via SentenceTransformer."""

    def test_loads_with_float32_on_cpu_and_verifies_dimension(self, tmp_path):
        mock_model = Mock()
        mock_model.get_sentence_embedding_dimension.return_value = 768
        mock_st_cls = Mock(return_value=mock_model)

        with patch("torch.cuda.is_available", return_value=False), \
             patch("aichat.model_manager.SentenceTransformer", mock_st_cls):

            model, processor = load_transformers_embedding_model("google/embeddinggemma-2", str(tmp_path))

            assert model == mock_model
            assert processor is None
            mock_st_cls.assert_called_once_with(
                str(tmp_path),
                device="cpu",
                model_kwargs={"torch_dtype": torch.float32}
            )
            mock_model.get_sentence_embedding_dimension.assert_called_once()

    def test_loads_fallback_to_model_id_when_local_dir_not_dir(self):
        mock_model = Mock()
        mock_model.get_sentence_embedding_dimension.return_value = 768
        mock_st_cls = Mock(return_value=mock_model)

        with patch("torch.cuda.is_available", return_value=False), \
             patch("aichat.model_manager.SentenceTransformer", mock_st_cls):

            model, processor = load_transformers_embedding_model("google/embeddinggemma-2", "/nonexistent/path")

            assert model == mock_model
            assert processor is None
            mock_st_cls.assert_called_once_with(
                "google/embeddinggemma-2",
                device="cpu",
                model_kwargs={"torch_dtype": torch.float32}
            )

    def test_raises_runtime_error_on_unexpected_dimension(self):
        mock_model = Mock()
        mock_model.get_sentence_embedding_dimension.return_value = 1024
        mock_st_cls = Mock(return_value=mock_model)

        with patch("torch.cuda.is_available", return_value=False), \
             patch("aichat.model_manager.SentenceTransformer", mock_st_cls):

            with pytest.raises(RuntimeError) as exc_info:
                load_transformers_embedding_model("google/embeddinggemma-2", "/fake/path")

            assert "reported dimension 1024" in str(exc_info.value)
            assert str(EMBEDDING_DIMENSION) in str(exc_info.value)


    def test_import_failure_reports_its_root_cause(self):
        """
        The package can be installed and still fail to import, so "is required"
        sent a frozen-build bug hunting in the wrong place. transformers re-wraps
        the real error as an ImportError, so the root must be dug out for the log,
        which only carries this one line.
        """
        real_import = builtins.__import__

        def failing_import(name, *args, **kwargs):
            if name == "sentence_transformers":
                try:
                    raise RuntimeError("operator torchvision::nms does not exist")
                except RuntimeError as root:
                    raise ModuleNotFoundError("Could not import module 'PreTrainedModel'") from root
            return real_import(name, *args, **kwargs)

        with patch("torch.cuda.is_available", return_value=False), \
             patch("aichat.model_manager.SentenceTransformer", None), \
             patch("builtins.__import__", side_effect=failing_import):

            with pytest.raises(RuntimeError) as exc_info:
                load_transformers_embedding_model("google/embeddinggemma-2", "/fake/path")

        assert "operator torchvision::nms does not exist" in str(exc_info.value)
        assert isinstance(exc_info.value.__cause__, ImportError)

    def test_root_cause_follows_implicit_chaining(self):
        """A wrapper raised inside `except` without `from` must not hide the original."""
        original = RuntimeError("original")
        wrapper = ImportError("wrapper")
        wrapper.__context__ = original

        assert _root_cause(wrapper) is original

    def test_root_cause_stops_on_a_cycle(self):
        """Failing to report an error must not hang the embedding request."""
        first = ImportError("first")
        second = RuntimeError("second")
        first.__cause__ = second
        second.__context__ = first

        assert _root_cause(first) is second


class FakeSentenceTransformer:
    def __init__(self, return_nan=False):
        self.recorded_inputs = None
        self.temp_file_existed = {}
        self.return_nan = return_nan

    def encode(self, inputs, normalize_embeddings=True, convert_to_numpy=True):
        self.recorded_inputs = inputs
        for item in inputs:
            if isinstance(item, dict):
                if "audio" in item:
                    self.temp_file_existed["audio"] = os.path.exists(item["audio"])
                if "video" in item:
                    self.temp_file_existed["video"] = os.path.exists(item["video"])

        if self.return_nan:
            arr = np.ones((len(inputs), 768), dtype=np.float32)
            arr[0, 0] = float("nan")
            return arr

        # Return mock embeddings: vector index i has value (i + 1)
        arr = np.zeros((len(inputs), 768), dtype=np.float32)
        for i in range(len(inputs)):
            arr[i, :] = float(i + 1)
        return arr


class TestGenerateTransformersMultimodalEmbedding:
    """Multimodal input formatting, task prompt prefixes, temp file lifecycle, and validation."""

    def test_text_document_prompt_by_default(self):
        fake_model = FakeSentenceTransformer()
        result = generate_transformers_multimodal_embedding(
            model=fake_model,
            texts=["Sample document"],
            task="document"
        )
        assert len(result) == 1
        assert fake_model.recorded_inputs == [f"{DOCUMENT_PROMPT}Sample document"]
        assert len(result[0]) == 768

    def test_text_query_prompt_with_query_task(self):
        fake_model = FakeSentenceTransformer()
        result = generate_transformers_multimodal_embedding(
            model=fake_model,
            texts=["Search query"],
            task="query"
        )
        assert len(result) == 1
        assert fake_model.recorded_inputs == [f"{QUERY_PROMPT}Search query"]

    def test_images_passed_without_prefix(self):
        fake_model = FakeSentenceTransformer()
        result = generate_transformers_multimodal_embedding(
            model=fake_model,
            images_base64=[VALID_PNG_B64],
            task="document"
        )
        assert len(result) == 1
        assert len(fake_model.recorded_inputs) == 1
        entry = fake_model.recorded_inputs[0]
        assert isinstance(entry, dict)
        assert "image" in entry
        assert isinstance(entry["image"], Image.Image)

    def test_audio_and_video_temp_files_lifecycle(self):
        fake_model = FakeSentenceTransformer()
        result = generate_transformers_multimodal_embedding(
            model=fake_model,
            audios_base64=[DUMMY_AUDIO_B64],
            videos_base64=[DUMMY_VIDEO_B64],
            filename="sample.mp4"
        )
        assert len(result) == 2
        assert fake_model.temp_file_existed.get("audio") is True
        assert fake_model.temp_file_existed.get("video") is True

        audio_path = fake_model.recorded_inputs[0]["audio"]
        video_path = fake_model.recorded_inputs[1]["video"]
        # Temp files must be cleaned up after encode returns
        assert not os.path.exists(audio_path)
        assert not os.path.exists(video_path)

    def test_output_order_matches_input_order(self):
        fake_model = FakeSentenceTransformer()
        result = generate_transformers_multimodal_embedding(
            model=fake_model,
            texts=["text 1", "text 2"],
            images_base64=[VALID_PNG_B64],
            audios_base64=[DUMMY_AUDIO_B64],
            videos_base64=[DUMMY_VIDEO_B64],
            task="document"
        )
        assert len(result) == 5
        # Modality order: texts -> images -> audios -> videos
        assert fake_model.recorded_inputs[0] == f"{DOCUMENT_PROMPT}text 1"
        assert fake_model.recorded_inputs[1] == f"{DOCUMENT_PROMPT}text 2"
        assert "image" in fake_model.recorded_inputs[2]
        assert "audio" in fake_model.recorded_inputs[3]
        assert "video" in fake_model.recorded_inputs[4]

        # Vectors should match order of fake model outputs
        assert result[0][0] == 1.0
        assert result[1][0] == 2.0
        assert result[2][0] == 3.0
        assert result[3][0] == 4.0
        assert result[4][0] == 5.0

    def test_invalid_task_raises_value_error(self):
        fake_model = FakeSentenceTransformer()
        with pytest.raises(ValueError) as exc_info:
            generate_transformers_multimodal_embedding(
                model=fake_model,
                texts=["Hello"],
                task="invalid_task"
            )
        assert "Invalid task" in str(exc_info.value)

    def test_nan_output_raises_value_error(self):
        fake_model = FakeSentenceTransformer(return_nan=True)
        with pytest.raises(ValueError) as exc_info:
            generate_transformers_multimodal_embedding(
                model=fake_model,
                texts=["Hello"]
            )
        assert "NaN" in str(exc_info.value)


class TestGenerateEmbeddingsLlamaCppMultimodalGuard:
    """LlamaCpp path in generate_embeddings must reject non-text modalities."""

    def test_llamacpp_rejects_images(self):
        mock_model = Mock()
        mock_model.client.embed = Mock()
        with pytest.raises(ValueError) as exc_info:
            generate_embeddings(mock_model, None, images_base64=[VALID_PNG_B64])
        assert "multimodal" in str(exc_info.value).lower() or "image" in str(exc_info.value).lower()

    def test_llamacpp_rejects_audios(self):
        mock_model = Mock()
        mock_model.client.embed = Mock()
        with pytest.raises(ValueError) as exc_info:
            generate_embeddings(mock_model, None, audios_base64=[DUMMY_AUDIO_B64])
        assert "multimodal" in str(exc_info.value).lower()

    def test_llamacpp_rejects_videos(self):
        mock_model = Mock()
        mock_model.client.embed = Mock()
        with pytest.raises(ValueError) as exc_info:
            generate_embeddings(mock_model, None, videos_base64=[DUMMY_VIDEO_B64])
        assert "multimodal" in str(exc_info.value).lower()

    def test_llamacpp_allows_text(self):
        mock_model = Mock()
        mock_model.client.embed.return_value = [0.1, 0.2]
        result = generate_embeddings(mock_model, None, texts=["hello"])
        assert result == [[0.1, 0.2]]
        mock_model.client.embed.assert_called_once_with("hello")
