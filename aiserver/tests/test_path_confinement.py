"""
Tests for path confinement on the thumbnail (H2) and PST-import (M1) endpoints.

Intent: caller-supplied paths must stay inside the app's own data directories.
The thumbnail endpoint must not read images from anywhere on disk, and PST
attachment extraction must not create dirs or write files outside output_dir —
even when the PST's folder names are hostile.
"""
import json
import os

import pytest
from fastapi import HTTPException

from aichat.routes import _assert_within_roots
from aichat.utils import resolve_data_roots


# --- _assert_within_roots -------------------------------------------------

def test_file_inside_root_is_allowed(tmp_path):
    root = tmp_path / "collection"
    root.mkdir()
    f = root / "photo.nef"
    f.write_bytes(b"x")
    assert _assert_within_roots(str(f), [str(root)]) == os.path.realpath(str(f))


def test_file_outside_root_is_rejected(tmp_path):
    root = tmp_path / "collection"
    root.mkdir()
    outside = tmp_path / "secret.jpg"
    outside.write_bytes(b"x")
    with pytest.raises(HTTPException) as exc:
        _assert_within_roots(str(outside), [str(root)])
    assert exc.value.status_code == 403


def test_sibling_prefix_cannot_escape(tmp_path):
    # '/a/collection' must not be treated as containing '/a/collection-evil'.
    root = tmp_path / "collection"
    root.mkdir()
    sibling = tmp_path / "collection-evil"
    sibling.mkdir()
    target = sibling / "x.jpg"
    target.write_bytes(b"x")
    with pytest.raises(HTTPException):
        _assert_within_roots(str(target), [str(root)])


def test_symlink_escape_is_rejected(tmp_path):
    root = tmp_path / "collection"
    root.mkdir()
    secret = tmp_path / "secret.jpg"
    secret.write_bytes(b"x")
    link = root / "innocent.jpg"
    os.symlink(str(secret), str(link))
    # realpath resolves the link to the out-of-root target, so it must be rejected.
    with pytest.raises(HTTPException):
        _assert_within_roots(str(link), [str(root)])


def test_empty_roots_rejects_everything(tmp_path):
    f = tmp_path / "x.jpg"
    f.write_bytes(b"x")
    with pytest.raises(HTTPException):
        _assert_within_roots(str(f), [None, ""])


# --- resolve_data_roots ---------------------------------------------------

def test_resolve_data_roots_includes_storage_from_config(tmp_path, monkeypatch):
    support = tmp_path / "support"
    support.mkdir()
    storage = tmp_path / "external_drive" / "mydata"
    storage.mkdir(parents=True)
    (support / "config.json").write_text(json.dumps({"storage": str(storage)}))

    monkeypatch.setenv("APP_SUPPORT_DIR", str(support))
    roots = resolve_data_roots()

    assert os.path.realpath(str(support)) in roots
    assert os.path.realpath(str(storage)) in roots
