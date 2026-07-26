---
name: run-mydatastudio-desktop
description: Build, run, and drive My Data Studio Desktop — the Flutter macOS client and its Python aiserver. Use when asked to start the app, run it, build it, screenshot its UI, drive the local LLM server, or verify a change works in the running app.
---

My Data Studio Desktop is a **Flutter macOS desktop app** (`client/`) plus an
**embedded Python FastAPI LLM server** (`aiserver/`). Two binaries, one app: at
startup the client normally spawns the bundled `aiserver` binary as a subprocess.
For development you drive them **decoupled** — run the aiserver yourself and point
the client at it. This skill was authored and verified on **macOS (Apple Silicon)**;
it is a native macOS GUI, so there is no Linux/headless path.

All paths below are relative to the repo root (the unit). The two drivers live in
`.claude/skills/run-mydatastudio-desktop/`:

- **`aiserver_smoke.sh`** — launches the Python server and drives it with `curl`. This is the fast path and what most PRs (which touch `aiserver/`) actually need.
- **`launch_client.sh`** — builds & launches the Flutter macOS app wired to an external aiserver, then you screenshot it with the computer-use MCP.

## Prerequisites

Already present on this dev Mac (versions verified this session):

- **Flutter** (`/Users/mikenimer/Development/libraries/flutter/bin/flutter`), macOS desktop device enabled
- **pdm 2.26** with the aiserver venv already installed. Note the venv resolves to the **main checkout's** `.venv` (`<main-repo>/aiserver/.venv`), shared across git worktrees — you do **not** re-run `pdm install` per worktree.
- **Xcode** + CocoaPods (first `flutter run` compiles the macOS pods).
- `curl`, `python3` for the smoke driver.

No GGUF models and no Python binary build are required to run either driver (see Gotchas).

## Run: aiserver (agent path — start here)

```bash
.claude/skills/run-mydatastudio-desktop/aiserver_smoke.sh
```

Launches `pdm run python main.py` (from `aiserver/`) on port 8117, waits for it,
then checks `GET /` (health), `GET /skills`, and `POST /util/model-status`. Prints
`ALL CHECKS PASSED` and kills the server on exit. Override the port with
`AICHAT_PORT=8128 .claude/skills/.../aiserver_smoke.sh`.

Manual equivalent (what the script runs):

```bash
cd aiserver
AICHAT_PORT=8117 AISERVER_LOG_LEVEL=info pdm run python main.py &   # server picks 0=random if unset
curl -s http://127.0.0.1:8117/ | python3 -m json.tool                # {"status":"online", ...}
curl -s http://127.0.0.1:8117/skills                                 # built-in skill registry
```

Key endpoints: `GET /`, `GET /skills`, `POST /v1/chat/completions`,
`POST /v1/embeddings`, `POST /util/model-status`, `POST /util/download-model`,
`POST /util/import/pst`.

### Direct invocation (no server)

The aiserver is a plain Python package — import and call without HTTP:

```bash
cd aiserver
pdm run python -c "import sys; sys.path.insert(0,'src'); from aichat import utils; print(utils._resolve_models_base())"
```

## Run: client (agent path)

```bash
.claude/skills/run-mydatastudio-desktop/launch_client.sh
```

This starts the aiserver on 8117, runs `flutter pub get`, then launches
`flutter run -d macos --dart-define=PYTHON_SERVER_URL=http://127.0.0.1:8117`
and waits for the `Flutter run key commands` marker (first build ~a few min for
pods; a cached rebuild launches in ~30s). It prints the flutter + aiserver PIDs
and a log path (`/tmp/mds_client_run.log`).

Then screenshot with the **computer-use MCP** (the plain `screencapture` CLI
fails here — see Gotchas):

1. `request_access(["MyDataStudio"])`
2. `open_application("com.xdtlabs.mydatastudio.dev")`
3. `screenshot(save_to_disk=true)`

Stop when done: `kill <flutter_pid> <aiserver_pid>` (or `pkill -f mydatastudio.app`
+ free port 8117). Do **not** kill a pre-existing app instance you didn't start.

Verified this session: the app compiled, launched, logged
`[python] Starting remote AI Chat service at: http://127.0.0.1:8117`, and rendered
the file browser (Local Files → headshots, image previews, File Details panel).

## Run (human path)

```bash
cd client && flutter run -d macos --dart-define=PYTHON_SERVER_URL=http://127.0.0.1:8117
# a native window opens; press q in the flutter console to quit
```

The README's `flutter run --dart-define-from-file=config/secrets.json` is stale —
that file does not exist; the dart-defines are optional OAuth provider keys.

## Test

```bash
cd aiserver && PYTHONPATH=src pdm run pytest tests/ -q   # 55 pass, 12 fail (pre-existing) this session
cd client && flutter test                                # 282 pass, 1 fail (boilerplate widget_test.dart)
```

`PYTHONPATH=src` is **required** — the tests `import aichat.*` but the package
lives under `src/` and `pytest.ini` sets no `pythonpath`. Plain `pdm run pytest
tests/` fails collection with `ModuleNotFoundError: No module named 'aichat'`.
The 12 aiserver failures and the 1 Flutter failure are pre-existing on this tree,
not caused by setup.

## Gotchas

- **`PYTHON_SERVER_URL` dart-define bypasses the bundled binary.** `python_manager.dart:77` reads it; when set, the client connects to your external aiserver instead of unzipping/spawning the bundled `aiserver` binary. This is the whole reason you don't need `make build-python` or downloaded GGUF models to run the GUI.
- **aiserver runs without models.** If the `models/` dir is empty the server logs `not found locally. Skipping auto-load` and still serves `/`, `/skills`, and `/util/model-status`. You only need multi-GB GGUFs for actual chat/embedding inference.
- **Login needs a `keys` directory.** The client authenticates against `<storage>/keys`, where `<storage>` comes from `~/Library/Application Support/com.xdtlabs.mydatastudio.dev/config.json` (here it points at a Drobo NAS: `/Volumes/Drobo5N/.../dev-1`). If that dir is missing/empty the app logs `⛔ Login error: Exception: Keys not found at ... Stopping application.` and sits on the login screen. On a clean machine without that config + keys, expect to land on login, not the file browser.
- **`screencapture` CLI is blocked.** Run from Bash it returns `could not create image from display` (the terminal lacks macOS Screen Recording permission). Use the computer-use MCP screenshot tool instead.
- **pdm venv is shared across worktrees.** `pdm info` in a worktree reports the interpreter under the **main** checkout's `.venv`. Deps installed there are already available — don't expect a per-worktree `.venv`.
- **No `build_runner` needed for the current tree.** There are no `part '*.g.dart'` directives in `lib/`, so the committed source compiles as-is. Only re-run `dart run build_runner build` after you change Drift tables or `@JsonSerializable` classes.

## Troubleshooting

- **`Address already in use` / stale server on 8117**: `lsof -ti :8117 | xargs kill`, then relaunch.
- **`flutter run` exits with pod/CocoaPods errors on first build**: it's compiling `macos/Pods`; let it finish (minutes). Warnings like `POD_CONFIGURATION_DEBUG macro redefined` are noise, not failures.
- **Screenshot shows the wrong window / two instances**: both a pre-existing and your fresh build share bundle id `com.xdtlabs.mydatastudio.dev`; `open_application` fronts one of them. Kill the instance you didn't start before screenshotting if you need certainty.
