# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

MyData/Tools Desktop is a local-first personal data archive & management tool. Letting users view and search their local drives, cloud drives, email, photos, and social media entirely on-device. AI-powered search and chat uses local LLMs (no cloud API calls).

The app has two runtime components:
1. **Flutter macOS desktop client** (`client/`) — the UI and data layer
2. **Python FastAPI service** (`client/assets/python/aichat/`) — embedded in the flutter app and spawned as a subprocess at startup, handles all LLM inference and embeddings over HTTP on localhost

## GSTACK
gstack is a process, not a collection of tools. The skills run in the order a sprint runs:

Think → Plan → Build → Review → Test → Ship → Reflect
Each skill feeds into the next. /office-hours writes a design doc that /plan-ceo-review reads. /plan-eng-review writes a test plan that /qa picks up. /review catches bugs that /ship verifies are fixed. Nothing falls through the cracks because every step knows what came before it.

- use the /browse skill from gstack for all web browsing, never use mcp__claude-in-chrome__* tools

lists the available skills: ( if gstack skills aren't working, run cd .claude/skills/gstack && ./setup to build the binary and register skills.)

### Planning & Review
- `/office-hours` — YC-style forcing questions to pressure-test product ideas and demand reality
- `/plan-ceo-review` — CEO/founder-mode plan review: rethinks the problem, challenges scope, finds the 10-star product
- `/plan-eng-review` — Eng manager-mode plan review: locks in architecture, data flow, edge cases, test coverage
- `/plan-design-review` — Designer's eye plan review: rates each design dimension 0-10 and fixes gaps before implementation
- `/design-consultation` — Full design system proposal: aesthetic, typography, color, layout, spacing, motion; produces DESIGN.md

### Shipping
- `/review` — Pre-landing PR review: checks SQL safety, LLM trust boundaries, conditional side effects, structural issues
- `/ship` — Full ship workflow: merge base, run tests, bump VERSION, update CHANGELOG, commit, push, create PR
- `/land-and-deploy` — Merges the PR, waits for CI/deploy, verifies production health via canary checks

### Quality & Testing
- `/qa` — Systematically QA test the app, find bugs, fix them in source, commit each fix atomically, re-verify
- `/qa-only` — Report-only QA: produces structured bug report with health score and repro steps, never fixes
- `/canary` — Post-deploy canary monitoring: watches live app for console errors, perf regressions, page failures
- `/benchmark` — Performance regression detection: establishes baselines for page load, Core Web Vitals, resource sizes

### Debugging
- `/investigate` — Systematic root-cause debugging: four phases (investigate, analyze, hypothesize, implement). No fixes without root cause.

### UI / Design
- `/design-review` — Designer's eye QA on a live/built site: finds visual inconsistency, spacing issues, hierarchy problems, AI slop; fixes and commits
- `/browse` — Headless browser for navigating URLs, interacting with elements, taking screenshots, testing forms
- `/setup-browser-cookies` — Import cookies from your real Chromium browser into the headless browse session

### Security
- `/cso` — Chief Security Officer audit: secrets archaeology, dependency supply chain, CI/CD security, OWASP Top 10, STRIDE threat modeling

### Safety & Guardrails
- `/careful` — Warns before destructive commands (rm -rf, DROP TABLE, force-push, reset --hard, kubectl delete)
- `/freeze` — Restrict file edits to a specific directory for the session; prevents accidental changes outside scope
- `/guard` — Full safety mode: combines /careful + /freeze for maximum protection
- `/unfreeze` — Clear the freeze boundary set by /freeze, allowing edits to all directories again

### Maintenance & Docs
- `/retro` — Weekly engineering retrospective: analyzes commit history, work patterns, code quality metrics
- `/document-release` — Post-ship docs update: refreshes README/ARCHITECTURE/CHANGELOG to match what shipped

### Infrastructure
- `/setup-deploy` — Configure deployment settings for /land-and-deploy (detects Fly.io, Render, Vercel, Netlify, etc.)

### Tooling
- `/codex` — OpenAI Codex CLI wrapper: code review (pass/fail gate), adversarial challenge mode, or consult mode
- `/gstack-upgrade` — Upgrade gstack to the latest version


## Build Commands

All orchestration goes through `make` from the repo root:

```bash
make all              # Build models + python binary + Flutter client
make dev              # Build models + python binary + install locally (no Flutter build)
make models           # Download GGUF models from Hugging Face
make build-python     # Compile Python service to binary via PyInstaller
make local-install-python  # Install Python binary to ~/Library/Application Support/
make build-client     # Build Flutter macOS release
make clean            # Remove all build artifacts
```

## Flutter Client (`client/`)

```bash
cd client
flutter pub get                      # Install dependencies
dart run build_runner build          # Regenerate Drift DB code and JSON serializers (required after schema changes)
flutter build macos --release --no-tree-shake-icons
flutter test                         # Run Flutter tests
```

> `dart run build_runner build` must be re-run whenever you modify Drift table definitions or classes annotated with `@JsonSerializable`.

## Python Service (`client/assets/python/aichat/`)

```bash
cd client/assets/python/aichat
pdm install                          # Install dependencies
python main.py                       # Run dev server (Uvicorn on random port)
pytest tests/ -v                     # Run full test suite (120+ tests)
pytest tests/test_routes.py -v       # Run a single test file
pdm run pyinstaller -y main.spec     # Compile to standalone binary
```

## Architecture

### Flutter → Python Communication

On startup, `PythonManager` spawns the bundled `aichat` binary as a subprocess and parses its stderr for a URL pattern (`http://0.0.0.0:PORT`). Once found, that URL is broadcast via `MainApp.llmServiceUrl` (a `BehaviorSubject`) so all subscribers can start making HTTP calls.

`LocalLlmContentGenerator` wraps those HTTP calls behind the `ContentGenerator` interface. Key endpoints:

| Endpoint | Purpose |
|---|---|
| `POST /start-session` | Load GGUF model into memory |
| `POST /chat` | Generate/stream chat response |
| `POST /embedding` | Text or image embeddings |
| `POST /import/pst` | Parse Outlook PST files |
| `POST /download-model` | Download models from Hugging Face |

On app close, `windowManager.onWindowClose` triggers `pythonManager.stopAiChatService()` (SIGTERM → 5s → SIGKILL).

### Flutter State & Data Flow

- **Global singletons**: `MainApp.supportDirectory`, `MainApp.appDataDirectory`, `MainApp.llmServiceUrl` — all `BehaviorSubject` from RxDart
- **Database**: `DatabaseManager` is a Drift singleton; write-heavy operations run in `DbIsolateWriter` (a separate `Isolate`) to avoid blocking the UI thread
- **Embeddings**: Generated in `EmbeddingIsolate` — another separate isolate
- **Background sync**: `ScannerManager` creates `CollectionScanner` instances per collection; scanners run as isolates watching for new/changed files, emails, photos
- **Auth**: `DesktopOAuthManager` handles OAuth2 flows for Google Drive, Gmail, Yahoo

Data flow: UI → Repository (Drift query) → SQLite + sqlite_vector → Scanner/Service (background) → Python HTTP for AI tasks → response back to UI

### Flutter Module Structure

`client/lib/modules/` contains feature modules. Each follows the pattern:
```
modules/<feature>/
  pages/      # Screens / routes
  widgets/    # UI components
  services/   # Business logic
```

Other key directories:
- `repositories/` — Drift query layer
- `services/` — cross-feature services
- `scanners/` — background isolate workers
- `file_sources/` — OAuth provider integrations (Google Drive, local FS)
- `models/` — Drift table definitions and JSON-serializable models

### Python Service Structure

```
main.py           # Uvicorn entry point
routes.py         # FastAPI route handlers
model_manager.py  # LLM inference and embeddings (llama-cpp-python)
state.py          # Global model instances, async locks
models.py         # Pydantic request/response schemas
pst_parser.py     # Outlook PST extraction (libpff)
genui_schema.py   # GenUI JSON response format
config.py         # Constants, default model paths
utils.py          # HuggingFace downloads, file I/O
```

### Database Schema

Drift tables: `App`, `AppUser`, `Collection`, `File`, `Folder`, `Email`, `EmailFolder`, `Album`, `FileEmbedding`. Collections own Files/Folders/Emails. `FileEmbedding` stores float vectors via sqlite_vector for semantic search.

### macOS Bundle IDs

- `main` branch → `mydata.tools`
- `develop` branch → `mydata.tools.dev`

Set via `make set-bundle-id` or controlled by `REALM_NAME` dart-define at build time.
