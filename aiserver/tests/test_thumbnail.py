"""
Tests for the thumbnail endpoint's bytes-in/bytes-out contract.

The handler decodes the source image from the request body (base64) and never
opens a filesystem path — this is the structural fix for AUDIT H2. These tests
pin that contract: a valid image produces a downscaled JPEG, and the request
model no longer carries any path field an attacker could point off-disk.
"""
import base64
import io

import pytest
from fastapi import HTTPException
from PIL import Image

from aichat.models import ThumbnailRequest
from aichat.routes import generate_thumbnail


def _png_base64(width: int, height: int) -> str:
    img = Image.new("RGB", (width, height), color=(255, 0, 0))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("utf-8")


def test_thumbnail_downscales_large_image():
    req = ThumbnailRequest(image_base64=_png_base64(800, 600), width=320, height=240)
    result = generate_thumbnail(req)

    assert result["format"] == "JPEG"
    # Aspect ratio preserved, longest side within the requested box.
    assert result["width"] <= 320
    assert result["height"] <= 240
    # The returned payload is a decodable JPEG.
    decoded = base64.b64decode(result["thumbnail"])
    out = Image.open(io.BytesIO(decoded))
    assert out.format == "JPEG"


def test_thumbnail_handles_data_uri_prefix():
    payload = "data:image/png;base64," + _png_base64(100, 100)
    result = generate_thumbnail(ThumbnailRequest(image_base64=payload))
    assert result["format"] == "JPEG"


def test_thumbnail_converts_rgba_to_rgb():
    # RGBA can't be saved as JPEG without conversion — the handler must normalize.
    img = Image.new("RGBA", (50, 50), color=(0, 255, 0, 128))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    payload = base64.b64encode(buf.getvalue()).decode("utf-8")

    result = generate_thumbnail(ThumbnailRequest(image_base64=payload))
    assert result["format"] == "JPEG"


def test_thumbnail_rejects_invalid_base64():
    with pytest.raises(HTTPException) as exc:
        generate_thumbnail(ThumbnailRequest(image_base64="!!!not base64!!!"))
    assert exc.value.status_code == 400


def test_thumbnail_rejects_non_image_bytes():
    payload = base64.b64encode(b"this is not an image").decode("utf-8")
    with pytest.raises(HTTPException) as exc:
        generate_thumbnail(ThumbnailRequest(image_base64=payload))
    assert exc.value.status_code == 500


def test_request_model_has_no_path_field():
    # Regression guard for H2: no path/allowed_root fields on the request.
    fields = set(ThumbnailRequest.model_fields.keys())
    assert "file_path" not in fields
    assert "allowed_root" not in fields
    assert "image_base64" in fields
