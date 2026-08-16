# MyDataStudio Desktop — Quickstart

**MyDataStudio** is a privacy-focused, local-first personal data manager and archive for your digital life. It keeps copies of your files, email, photos, and social media on your device—entirely searchable with semantic AI—without sending data to a cloud service.

## Key Features

- **Local-first**: All data stored on your device; no mandatory cloud upload to My Data Studio
- **Privacy-focused**: AI search and chat run using locally-bundled LLM models (offline-capable); optional cloud providers (Gemini, Claude, OpenAI, Grok) available **only if you provide your own API key**
- **Cross-source**: Archive local filesystem, Google Drive, Gmail, Yahoo Mail, Outlook (IMAP or `.pst` import)
- **Semantic search**: Embedding-based search across files, email, photos, and metadata
- **Multiple views**: File browser, email client, photo gallery with timeline/map/grid/list views, and AI chat interface
- **Open-source**: Apache 2.0 licensed; built with Flutter + Python

## What's Inside

MyDataStudio is a **hybrid desktop application** with two runtime components:

| Component | Technology | Purpose |
|-----------|-----------|---------|
| **UI & Data** | Flutter (Dart) + SQLite (`resqlite`/`resqlite_vector`) | Desktop interface, local metadata & vector storage |
| **AI Engine** | Python FastAPI (bundled subprocess) | Local LLM inference, embeddings, email parsing (PST) |
| **Background Tasks** | Dart isolates (parallel scanners, embedding generators) | File/email sync, semantic indexing |
| **State** | RxDart (`BehaviorSubject`) | Reactive app-wide and page-level state |

Both the Flutter client and Python service are bundled together in the final app; the Python service is spawned as a child process on launch and communicates with the UI over HTTP on localhost with bearer-token auth.

## Architecture & Design

For a detailed technical overview, see [**Architecture Overview**](./architecture/overview.md), which covers:

- Startup sequence and initialization
- Data flow (files, email, photos)
- SQLite schema and model design
- Isolate architecture and write-relay consistency pattern
- Python service endpoints and communication

## Modules & Features

The app is organized into feature modules. See the module guides for deep dives:

- **[Files & Photos](./modules/files-and-photos.md)** — File browser (local + Google Drive), gallery views (timeline, grid, list, map, cluster), album management
- **[Search](./modules/search.md)** — Unified cross-source search (BM25 + vector + geo), query parsing, person resolution, result summarization
- **[Email](./modules/email.md)** — Multi-provider email archive (Gmail, Outlook, Yahoo), message search, attachment handling
- **[AI Chat](./modules/aichat.md)** — Semantic search & chat across all data, local GGUF models, optional cloud passthrough

## Getting Started

### Prerequisites

- **macOS** with Xcode (currently the only supported platform)
- [Flutter](https://flutter.dev) 3.44.8+ (includes Dart 3.12+)
- Python 3.11–3.14 with [pdm](https://pdm-project.org/) installed
- [`hf` CLI](https://huggingface.co/docs/huggingface_hub/guides/cli) for downloading GGUF models (`pip install -U "huggingface_hub[cli]"`)

### Clone & Build

```bash
git clone https://github.com/XDT-Labs/mydatatools-desktop
cd mydatatools-desktop
```

All orchestration goes through the **Makefile**. For local development:

```bash
make models           # Download GGUF models from Hugging Face (one-time, several GB)
make dev              # Build Python service and install locally
cd client && flutter pub get && flutter run -d macos
```

For a full release build:

```bash
make all              # Build models + Python binary + Flutter client
```

See [**Building & Operations**](./operations/building.md) for more detail on Makefile targets, Flutter-only builds, Python-only development, and testing.

### Common Workflows

#### Running the Flutter client with hot reload (development)
```bash
make dev
cd client
flutter pub get
flutter run -d macos
```

#### Testing the Python service standalone
```bash
cd aiserver
pdm install
python main.py          # Starts a dev server on a random port
PYTHONPATH=src pdm run pytest  # Run the full test suite
```

#### Running just the Flutter tests
```bash
cd client
flutter test
```

#### Building a release `.app` (bundled Python + Flutter)
```bash
make all
# Result: client/build/macos/Build/Products/Release/mydatastudio.app
```

#### Code signing & macOS notarization
```bash
export APPLE_ID=your-apple-id@example.com
export APPLE_PASSWORD=your-app-specific-password
export APPLE_TEAM_ID=XXXXXXXXXXX
make notarize
```

## Repository Structure

```
/client/                    # Flutter macOS desktop app
  lib/
    modules/                # Feature modules (files, photos, email, search, aichat, social)
    repositories/           # Data access layer (SQLite queries)
    services/               # Business logic (RxService base class, model download, auth, etc.)
    scanners/               # Scanner lifecycle management & registration
    file_sources/           # OAuth integrations (Google Drive, local FS)
    oauth/                  # OAuth2 desktop flow (Google, Yahoo)
    pages/                  # Top-level pages (Home, Login, Setup, Splash)
    models/tables/          # Database schema models (hand-written, no codegen)
    widgets/                # Reusable UI components
    database_manager.dart   # SQLite initialization, schema DDL, background services
    python_manager.dart     # Spawns/monitors Python service subprocess
    main.dart               # Global state (MainApp singletons), app entry point
  test/                     # 100+ unit & integration tests
  pubspec.yaml             # Flutter dependencies

/aiserver/                  # Python FastAPI service (bundled subprocess)
  src/aichat/
    main.py                 # FastAPI app definition
    routes.py               # Endpoints for chat, embeddings, models, skills
    model_manager.py        # Model registry & inference setup
    pst_parser.py           # Outlook PST email parsing
    models.py               # Pydantic request/response schemas
    auth.py                 # Bearer token validation
    config.py               # Configuration management
  tests/                    # pytest suite (routes, auth, model management, etc.)
  pyproject.toml            # pdm dependencies (FastAPI, llama-cpp-python, LangChain)
  main.spec                 # PyInstaller config (Metal GPU acceleration, model bundling)
  Readme.md                 # Python service development guide

/models/                    # Downloaded GGUF models (gitignored)
  gemma-4-12B-it-Q4_0.gguf
  mmproj-gemma-4-12B-it-Q8_0.gguf
  Qwen-Qwen3-VL-Embedding-2B-local/

/Makefile                   # Build orchestration (models, Python, Flutter, signing)
/ARCHITECTURE.md            # Detailed architecture doc (startup, modules, data flow)
/DESIGN.md                  # UI/theme design spec (dark theme, typography, colors)
/CLAUDE.md                  # AI assistant guidance (build commands, patterns)
/README.md                  # User-facing overview
```

## Key Architectural Patterns

### 1. Write Consistency: Main Isolate Bottleneck

Scanner isolates (file scanning, email parsing, embedding generation) cannot write directly to SQLite. Instead, they send write requests back to the main isolate via a control port. The main isolate's single AppDatabase connection serializes all writes, avoiding SQLITE_BUSY errors and ensuring a write's data is immediately visible to the next transaction.

See [Isolates & Write Relay](./architecture/isolates.md) for details.

### 2. Reactive State with RxDart

Global app state (LLM service URL, current user, support directory) and page-level state (file list, email folder, chat messages) are managed with RxDart `BehaviorSubject` and `PublishSubject` streams. No Provider, Bloc, or Riverpod—just plain subscriptions and manual `sink.add()` updates.

See [State Management](./data-flow/state-management.md) for details.

### 3. Hand-Written SQL Schema

There is **no Drift, no codegen, no ORM**. The SQLite schema is declared as raw DDL strings in `database_manager.dart`, and model classes are plain Dart with hand-written `fromMap()` and `toMap()` methods. Schema changes require editing the DDL and the corresponding model by hand.

See [Database Design](./architecture/database.md) for details.

### 4. Registration-Only Scanner Startup

`ScannerManager` only registers scanners at app startup; it does **not** trigger a sync. Users must manually trigger a sync by navigating to a collection or pressing a sync button. This avoids hammering the network or filesystem on every app launch.

See [Scanning & Sync Lifecycle](./data-flow/scanning.md) for details.

## Recent Work

### Photo Gallery Migration (PR #33)
The Photos module was recently migrated from a React mockup (Lumina Gallery) to a full Flutter desktop implementation with 4 view modes (grid, list, timeline, map), metadata editing, album management, and keyboard shortcuts. See [Photo Gallery Rewrite](./recent-changes/photo-gallery-migration.md).

### Write Consistency Refactor (PR #29)
Background isolates (scanner & embedding) now route all writes through the main isolate to eliminate SQLITE_BUSY contention and silent write failures. See [Write-Relay Refactor](./recent-changes/write-relay-refactor.md).

## Testing

The codebase includes **100+ tests** for Flutter and Python:

- **Flutter tests** (`client/test/`): Unit & integration tests for scanners, repositories, services, widgets, OAuth flows
- **Python tests** (`aiserver/tests/`): Tests for FastAPI routes, auth, model management, PST parsing, thumbnail generation

Run tests via:
```bash
cd client && flutter test
cd aiserver && PYTHONPATH=src pdm run pytest
```

See [Testing Guide](./operations/testing.md) for details.

## Next Steps

1. **[Architecture Overview](./architecture/overview.md)** — Understand the startup sequence, data flow, and module responsibilities
2. **[Database Design](./architecture/database.md)** — Learn about the SQLite schema, model design, and schema migration strategy
3. **[Isolates & Write Relay](./architecture/isolates.md)** — Deep dive into the isolate architecture and write consistency pattern
4. **[Building & Operations](./operations/building.md)** — See build targets, development workflows, and deployment steps
5. **Feature modules** — Explore [Files & Photos](./modules/files-and-photos.md), [Email](./modules/email.md), or [AI Chat](./modules/aichat.md)

---

## Backlog

- **Cloud provider setup** — Detailed OAuth credential walkthrough for each provider (Gmail, Google Drive, Yahoo, Outlook). (Source: `/DESIGN.md`, existing cloud provider docs; deferred for focus on architecture first)
- **Feature-specific deep dives** — PST parsing algorithm, EXIF extraction, vector database queries, embedding model details. (Source: `/aiserver/src/aichat/pst_parser.py`, library docs; useful but optional)
- **Testing deep-dive** — Test data fixtures, mocking strategies, integration test setup. (Source: `/client/test/helpers/`, `/aiserver/tests/conftest.py`; can be expanded later)
