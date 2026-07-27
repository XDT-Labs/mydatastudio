
### From PST import / logging cleanup (2026-07-26)

## aiserver test suite: 12 pre-existing failures, one of which segfaults

`PYTHONPATH=src pdm run pytest` in `aiserver/` reports **12 failed, 137 passed**. All 12
predate the PST/logging work — verified by diffing the failure set against a clean
checkout — but they were never triaged, and they hide regressions: a new failure is
invisible in a run that already has a dozen.

The failures:
- `tests/test_start_session.py` — 4 tests (model load/switch/404/500)
- `tests/test_routes.py::TestChatCompletion` — 3 tests
- `tests/test_model_manager.py` — `test_load_local_model_success`, `test_load_gemini_model_success`
- `tests/test_utils.py` — `test_get_local_path_formatting`, `test_download_gguf_model_if_needed_hf_download`
- `tests/test_fix_nonetype.py::test_get_local_path_with_none`

Most look like mocking drift — e.g. `test_load_local_model_success` passes `/fake/path/model.gguf`
and `llama_cpp.Llama` now raises `ValueError: Model path does not exist` before the mock is
reached, so the test is asserting against a constructor that changed under it.

**The one worth looking at first:** `tests/test_routes.py::TestChatCompletion::test_chat_completion_no_model_loaded`
does not merely fail — run on its own it **segfaults** (dyld crash, llama_cpp loading):

```bash
PYTHONPATH=src pdm run pytest tests/test_routes.py::TestChatCompletion::test_chat_completion_no_model_loaded
```

In the full suite it oscillates: it passed in one run and failed in the next four, moving the
total between 11 and 12 depending on ordering. A test that can crash the interpreter can take
the rest of the run with it, so the suite's result is not currently trustworthy.

Fix: triage the 12, get the suite to green (or explicitly xfail with a reason), and make the
segfaulting one either load no model or be skipped when llama_cpp can't initialise.