"""
Shared test isolation.

These tests are unit tests, but two pieces of production code reach outside the
process by design and will happily find the developer's real installation:

* ``utils._resolve_models_base()`` walks ``~/Library/Application Support`` for
  the app's bundle ids, so on a machine with the app installed it returns that
  directory instead of anything the test controls.
* ``model_registry.lookup()`` opens the real ``mydata.db`` named by the app's
  ``config.json`` and returns whatever models happen to be registered there.

Left alone, the two combine badly: a chat-completion test that mocked only
``get_llm_instance`` still hit the real registry, got a real row with real
absolute paths, and loaded a 12B GGUF into memory mid-test. Results also
differed between a machine with the app installed and CI.

This fixture is autouse so isolation is the default and a new test cannot
silently reach the real thing. A test that wants a registry row patches
``aichat.routes.model_registry.lookup`` itself; that patch is applied inside
this one and wins.
"""
import pytest

from aichat import model_registry


@pytest.fixture(autouse=True)
def isolate_from_developer_machine(tmp_path, monkeypatch):
    # Priority 1 in _resolve_models_base, so it short-circuits the
    # Application Support scan without the test caring how that scan works.
    monkeypatch.setenv("AICHAT_MODELS_DIR", str(tmp_path / "models"))

    # Pre-seed the resolution cache with a path that does not exist. lookup()
    # then takes its normal "no database" branch and returns None, exercising
    # the real function rather than a stub of it.
    monkeypatch.setattr(model_registry, "_db_path_cache", str(tmp_path / "absent.db"))
    monkeypatch.setattr(model_registry, "_db_resolution_attempted", True)

    yield
