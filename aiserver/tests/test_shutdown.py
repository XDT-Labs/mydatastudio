"""
Tests for POST /shutdown.

Intent: on Windows the client has no SIGTERM to send. Dart's Process.kill maps
to TerminateProcess there, which ends the server mid-write, so the client asks
over HTTP first and only kills it if that fails. The route ends the server the
way SIGTERM does on macOS and Linux (uvicorn's should_exit), and like every
other route it needs the bearer token, so a process that only finds the port
can't stop the app's AI service.
"""
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from aichat import main as server_main


TOKEN = "s" * 64


@pytest.fixture
def server(monkeypatch):
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    fake = SimpleNamespace(should_exit=False)
    monkeypatch.setattr(server_main, "_server", fake)
    return fake


def test_shutdown_with_the_token_stops_the_server(server):
    client = TestClient(server_main.app)
    response = client.post("/shutdown", headers={"Authorization": f"Bearer {TOKEN}"})
    assert response.status_code == 200
    assert server.should_exit is True


def test_shutdown_without_the_token_is_refused(server):
    client = TestClient(server_main.app)
    response = client.post("/shutdown")
    assert response.status_code == 401
    assert server.should_exit is False


def test_shutdown_before_the_server_runs_says_so(monkeypatch):
    # Under a test client or before uvicorn starts there is nothing to stop.
    # Claiming success would leave the caller waiting for an exit that never
    # comes; a 503 sends it straight to its kill fallback.
    monkeypatch.setenv("AISERVER_TOKEN", TOKEN)
    monkeypatch.setattr(server_main, "_server", None)
    client = TestClient(server_main.app)
    response = client.post("/shutdown", headers={"Authorization": f"Bearer {TOKEN}"})
    assert response.status_code == 503
