"""
Tests for the bearer-token auth dependency (AUDIT.md H1).

Intent: the local server must reject callers that don't present the token the
client was given, so a co-resident process that merely discovers the port can't
drive the file-read/write endpoints. When no token is configured (dev), auth is
disabled so local runs and the rest of the suite keep working.
"""
import pytest
from fastapi import HTTPException

from aichat.auth import require_token


TOKEN = "a" * 64


def test_no_token_configured_allows_any_request(monkeypatch):
    # Dev / backward-compatible mode: absent AISERVER_TOKEN => auth disabled.
    monkeypatch.delenv("AISERVER_TOKEN", raising=False)
    require_token(authorization=None)  # must not raise


def test_empty_token_configured_allows_any_request(monkeypatch):
    monkeypatch.setenv("AISERVER_TOKEN", "")
    require_token(authorization=None)  # must not raise


def test_correct_token_is_accepted(monkeypatch):
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    require_token(authorization=f"Bearer {TOKEN}")  # must not raise


def test_missing_header_is_rejected(monkeypatch):
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    with pytest.raises(HTTPException) as exc:
        require_token(authorization=None)
    assert exc.value.status_code == 401


def test_wrong_token_is_rejected(monkeypatch):
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    with pytest.raises(HTTPException) as exc:
        require_token(authorization="Bearer not-the-token")
    assert exc.value.status_code == 401


def test_wrong_scheme_is_rejected(monkeypatch):
    # A bare token or a different scheme must not satisfy the check.
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    with pytest.raises(HTTPException):
        require_token(authorization=TOKEN)
    with pytest.raises(HTTPException):
        require_token(authorization=f"Basic {TOKEN}")
