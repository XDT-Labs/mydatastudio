# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

My Data Studio Desktop is a local-first personal data archive & management tool. Letting users view and search their local drives, cloud drives, email, photos, and social media entirely on-device. AI-powered search and chat uses local LLMs (no cloud API calls).

The app has two runtime components:
1. **Flutter macOS desktop client** (`client/`) — the UI and data layer
2. **Python FastAPI service** (`aiserver/`) — embedded in the flutter app and spawned as a subprocess at startup, handles all LLM inference and embeddings over HTTP on localhost


## Build Commands

All orchestration goes through `make` from the repo root:

```bash
make all              # Build models + python binary + Flutter client
make dev              # Build models + python binary + install locally (no Flutter build)
make models           # Download default GGUF models from Hugging Face
make build-python     # Compile Python service to binary via PyInstaller (Metal-enabled on macOS)
make local-install-python   # Install Python binary to ~/Library/Application Support/<bundle-id>/ (dev + prod realms)
make build-client     # Build Flutter macOS release (swaps in pubspec.prod.yaml, passes REALM_NAME)
make notarize         # Notarize the macOS build (requires APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID)
make clean            # Remove all build artifacts
```

## Flutter Client (`client/`)

```bash
cd client
flutter pub get                      # Install dependencies
flutter build macos --release --no-tree-shake-icons
flutter test                         # Run Flutter tests
```

> The database uses **resqlite** (+ **resqlite_vector**), not Drift. Tables are declared as raw `CREATE TABLE IF NOT EXISTS` DDL in `database_manager.dart` (`AppDatabase.schemaDDL`), and models under `models/tables/` are plain Dart classes with hand-written `fromMap`/`toMap`. There is **no code generation** for the schema or models — a schema change means editing the DDL and the corresponding model by hand. There is no incremental schema-version counter; one-off migrations are gated by ad-hoc `PRAGMA user_version` checks and idempotent `ALTER TABLE ... IF NOT EXISTS`-style helpers run on every open.

## Python Service (`aiserver/`)

```bash
cd aiserver
pdm install                          # Install dependencies
python main.py                       # Run dev server (Uvicorn on random port)
PYTHONPATH=src pdm run pytest        # Run full test suite (tests/ + src/aichat/tests/)
PYTHONPATH=src pdm run pytest tests/test_routes.py   # Run a single test file
pdm run pyinstaller -y main.spec     # Compile to standalone binary
```

Requires Python 3.11–3.14 (`requires-python = ">=3.11,<3.15"` in `pyproject.toml`).

## Architecture

### Flutter → Python Communication

On startup, `PythonManager` unzips the bundled `aiserver-<platform>.zip` into Application Support (if not already installed at the current version), generates a per-launch bearer token, and spawns the `aiserver` binary as a subprocess with `APP_SUPPORT_DIR`/`AICHAT_MODELS_DIR`/`AISERVER_TOKEN` env vars. It scans subprocess stdout for a URL pattern (`http://127.0.0.1:PORT` or `http://localhost:PORT`). Once found, that URL is broadcast via `MainApp.llmServiceUrl` (a `BehaviorSubject`) so all subscribers can start making HTTP calls. A `PYTHON_SERVER_URL` dart-define can override this to point at an already-running dev server instead of spawning one.

`LocalLlmContentGenerator` wraps chat completion calls behind the `genui` package's `ContentGenerator` interface. All requests carry `Authorization: Bearer <AISERVER_TOKEN>`. Key endpoints actually called by the client:

| Endpoint | Purpose |
|---|---|
| `POST /v1/chat/completions` | Streaming/non-streaming chat completion (local GGUF or cloud provider passthrough) |
| `POST /v1/chat/stop` | Cancel an in-flight generation |
| `POST /util/embedding` | Text or image embeddings (local multimodal model) |
| `GET /util/model-status` | Check whether a model is already downloaded on disk |
| `POST /util/download-model` | Download a GGUF file or HF snapshot, streaming SSE progress |
| `POST /util/delete-model` | Delete a downloaded model |
| `POST /util/import/pst` | Stream-parse an Outlook PST file |
| `POST /util/thumbnail` | Generate an image thumbnail (incl. RAW formats) |
| `GET /skills` | List built-in `/command` skills |

On app close, `windowManager.onWindowClose` triggers `pythonManager.stopAiServerService()` (SIGTERM → 5s → SIGKILL).

### Flutter State & Data Flow

- **Global singletons**: `MainApp.supportDirectory`, `MainApp.appDataDirectory`, `MainApp.llmServiceUrl` — all `BehaviorSubject` from RxDart
- **Database**: only the main isolate's `AppDatabase` connection writes. Scanner and embedding isolates each open their own `AppDatabase` connection too, but use it for reads only (discovery queries, cache warm-up); every write is relayed over the isolate's existing control port (`{'type': 'dbWrite', ...}` for scanners, `{'type': 'embedding', ...}` for the embedding isolates) and executed on the main isolate's connection — see `scan_write_relay.dart` (`handleScanWriteMessage`) and `embedding_message_handler.dart` (`handleEmbeddingMessage`). Scanner isolates send via the shared `writeViaMain()` helper in `scan_isolate_support.dart` (30s timeout, guaranteed cleanup); `await for`-based scanners (local filesystem, Google Drive) get in-order processing for free from the loop, while `receivePort.listen(...)`-based scanners (Gmail, Outlook, Yahoo, PST) route through a `SequentialWriteQueue` on the main-isolate side to preserve write order despite listener callbacks not awaiting each other. This replaced an earlier design where every isolate wrote through its own connection directly, which caused `SQLITE_BUSY` contention and, worse, could silently no-op a write when a row inserted by one connection wasn't yet visible to another's guard clause. `DatabaseManager.startBackgroundServices` still staggers isolate startup by 500ms to avoid concurrent-open contention on connection creation itself.
- **Embedding Generation**: Generated in `EmbeddingIsolate` (files) and `EmailEmbeddingIsolate` (emails), each a separate `Isolate`; both pause while any scanner is actively syncing
- **Background sync**: `ScannerManager` creates `CollectionScanner` instances per collection; scanners run as isolates watching for new/changed files, emails, photos
- **Auth**: `DesktopOAuthManager` handles OAuth2 flows for Google Drive, Gmail, Yahoo

Data flow: UI → Repository (resqlite query) → SQLite + resqlite_vector → Scanner/Service (background) → Python HTTP for AI tasks → response back to UI

### Flutter Module Structure

`client/lib/modules/` contains feature modules. Each follows the pattern:
```
modules/<feature>/
  pages/      # Screens / routes
  widgets/    # UI components
  services/   # Business logic
```

Other key directories:
- `repositories/` — resqlite query layer
- `services/` — cross-feature services (includes `rx_service.dart`, the `RxService<C, R>` base class)
- `scanners/` — `CollectionScanner` base class + `ScannerManager` (registration/lifecycle, not the scanners themselves — those live per-module under `modules/<feature>/services/scanners/`)
- `file_sources/` — OAuth provider integrations (Google Drive, local FS)
- `models/` — plain Dart model classes (`models/tables/`) with hand-written `fromMap`/`toMap`; the SQL schema is declared in `database_manager.dart`

Implemented scanners (registered in `ScannerManager`): local filesystem, Google Drive, Gmail, Yahoo, Outlook (live IMAP). Outlook PST import is a one-time file import isolate invoked directly by the UI, not a registered scanner. Dropbox/OneDrive constants exist but have no implementation. The `social` module (Facebook/Twitter/Instagram) is UI-only placeholder pages with no backing scanner.

### Python Service Structure

```text
main.py           # Uvicorn entry point; creates the FastAPI app and registers all routes
routes.py         # Route handler implementations (chat, embeddings, model mgmt, PST, thumbnails)
model_manager.py  # Model loaders: local GGUF (llama-cpp-python) + Gemini/Claude/OpenAI/Grok passthrough
state.py          # Global model instance, asyncio load locks, threading generation lock, stop events
models.py         # Pydantic request/response schemas
model_registry.py # Resolves model aliases via Flutter's config.json + the aichat_models table
skills.py         # Built-in "/command" skill registry (summarize, analyze, translate, explain, rewrite)
pst_parser.py     # Outlook PST extraction (pypff / libpff)
auth.py           # Bearer-token auth dependency (enforced when AISERVER_TOKEN is set)
config.py         # Constants, default model paths
utils.py          # HuggingFace downloads, file I/O
```

Concurrency: one shared model instance at a time; a `threading.Lock` (`state.generation_lock`) serializes actual generations since `llama_cpp` isn't safe for concurrent decoding. Per-generation `threading.Event`s back `/v1/chat/stop` so a stop can target one stream without killing others.

### Database Schema

Tables (raw `CREATE TABLE` DDL in `database_manager.dart`): `apps`, `app_users`, `collections`, `files`, `folders`, `emails`, `email_folders`, `albums`, `providers`, `files_embeddings`, `emails_embeddings`, `aichat_conversations`, `aichat_conversation_history`, `aichat_models`, `aichat_skills`. Collections own Files/Folders/Emails. `files_embeddings`/`emails_embeddings` store float vectors (Qwen3-VL-Embedding-2B, dim 2048) via resqlite_vector for semantic search.

### macOS Bundle IDs

Both `main` and `develop` branches currently build to `com.xdtlabs.mydatastudio`; the realm/bundle id is controlled by `REALM_NAME` (read from `.realm_name` at build time, passed as a `--dart-define`) rather than a per-branch make target.

## Development Practices

- **Test-driven for non-trivial changes**: write a test that expresses the intended behavior before implementing, then implement to make it pass (red-green-refactor). Trivial one-liners don't need ceremony — use judgment, consistent with Rule 2 below.
- **Build before test**: run a build and fix compiler/analyzer errors before running the test suite — don't let test failures mask build breaks.
- **Regression tests**: when fixing a bug, add a test that would have caught it, not just the fix itself (see Rule 9).
- **Code qualities**: concrete enough to be understood, abstract enough to change; expose the problem's domain in naming; high cohesion / loose coupling; single responsibility per method/class.
- **Git commits**: never run `git commit` unless the user asked for a commit in the message being responded to. Code gets reviewed before it enters history.
  - Finishing work is not permission. Passing tests, a clean analyzer, a completed task, or a plan listing "commit" as a step are not approval — leave the work in the working tree and say it's ready.
  - Approval does not carry forward. "Commit this" authorizes that one commit; the next change needs its own ask, even later in the same session.
  - Commit exactly what was named, nothing else. Prefer explicit paths over `git add .` or `git add -A`, unstage unrelated changes, and report what remains uncommitted.
  - Same bar for anything outward-facing: no `git push`, branch deletion, PR creation, or merges unless asked in that message.
  - Exception: skills the user invokes that commit as part of their documented job (`/ship`, `/qa`, `/design-review`). Invoking one is the ask; the exception covers only that skill and ends when it does.
  - If a skill says to generate a commit message and stop, stop — don't upgrade that into running the commit.
- **Mermaid diagrams**: quote node labels that contain spaces, newlines, or special characters (`()`, `[]`, `{}`, etc.) to avoid syntax errors.




# Important Rules 

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists.
Stop when confused. Name what's unclear.

## Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
Test: would a senior engineer say this is overcomplicated? If yes, simplify.

## Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.

## Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Don't follow steps. Define success and iterate.
Strong success criteria let you loop independently.

## Rule 5 — Use the model only for judgment calls
Use me for: classification, drafting, summarization, extraction.
Do NOT use me for: routing, retries, deterministic transforms.
If code can answer, code answers.

## Rule 6 — Token budgets are not advisory
Per-task: 4,000 tokens. Per-session: 30,000 tokens.
If approaching budget, summarize and start fresh.
Surface the breach. Do not silently overrun.

## Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

## Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
"Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

## Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.

## Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.
If you lose track, stop and restate.

## Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you genuinely think a convention is harmful, surface it. Don't fork silently.

## Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.

<!-- OPENWIKI:START -->

## OpenWiki

This repository uses OpenWiki for recurring code documentation. Start with `openwiki/quickstart.md`, then follow its links to architecture, workflows, domain concepts, operations, integrations, testing guidance, and source maps.

The scheduled OpenWiki GitHub Actions workflow refreshes the repository wiki. Do not hand-edit generated OpenWiki pages unless explicitly asked; prefer updating source code/docs and letting OpenWiki regenerate.

<!-- OPENWIKI:END -->
