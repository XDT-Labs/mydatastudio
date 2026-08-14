# Architecture Overview

MyDataStudio is a hybrid application combining a **Flutter macOS client** (UI + local data) with a **Python FastAPI service** (AI engine) bundled as a subprocess. This document covers the high-level architecture, startup sequence, and data flows.

## System Architecture

```
┌─────────────────────────────────────────────────────┐
│  Flutter macOS App (client/)                        │
├─────────────────────────────────────────────────────┤
│  UI Layer          → Pages & Widgets                │
│  State Management  → RxDart (BehaviorSubject)      │
│  Data Access       → Repositories (SQLite queries)  │
│  Scanners          → Isolate-based background sync │
│  Services          → Business logic, model download │
├─────────────────────────────────────────────────────┤
│  AppDatabase (resqlite + resqlite_vector)          │
│  └─ Metadata + Vector storage (local SQLite)       │
└─────────────────────────────────────────────────────┘
          ↓  HTTP + Bearer Token Auth
┌─────────────────────────────────────────────────────┐
│  Python FastAPI Service (aiserver/)                │
│  (Bundled subprocess, spawned on app launch)        │
├─────────────────────────────────────────────────────┤
│  LLM Inference     → GGUF models (local)            │
│  Cloud Models      → Passthrough (Gemini/Claude/.. )│
│  Embeddings        → Qwen3-VL-Embedding-2B         │
│  Email Parsing     → PST file extraction            │
│  Thumbnail Gen     → Image processing (PIL)         │
└─────────────────────────────────────────────────────┘
```

## Technology Stack

| Component | Technology | Role |
|-----------|-----------|------|
| **UI Framework** | Flutter 3.44.8 (Dart 3.7+) | Cross-platform desktop interface |
| **Database** | SQLite + resqlite + resqlite_vector | Metadata, vector embeddings, query layer |
| **State** | RxDart (BehaviorSubject/PublishSubject) | Reactive state, no Provider/Bloc |
| **Background** | Dart Isolates | Parallel file/email scanning, embeddings |
| **AI Runtime** | Python 3.11–3.14 with FastAPI | LLM chat, embeddings, email parsing |
| **LLM Inference** | llama-cpp-python + GGUF models | Local Gemma-4 chat model |
| **Embeddings** | Transformers + Qwen3-VL-Embedding-2B | Text + vision embeddings |
| **Email Parsing** | libpff-python (PST) + email stdlib | Outlook PST + IMAP parsing |
| **Packaging** | PyInstaller (Metal GPU) | Python binary bundling |

## Startup Sequence

When the app launches, the following happens in order:

1. **Flutter Initialization**
   - Initialize Flutter bindings & MediaKit (desktop media framework)
   - Initialize window manager (desktop window setup)

2. **Check Database Configuration**
   - If database is not configured → show Setup page
   - If database is already configured → proceed to step 3

3. **Initialize AppDatabase**
   - Create SQLite connection on the main isolate
   - Execute schema DDL (`CREATE TABLE IF NOT EXISTS ...` statements)
   - Apply any idempotent schema migrations (ALTER TABLE, etc.)

4. **Initialize PythonManager**
   - Unzip bundled `aiserver-<platform>.zip` into Application Support folder (if not already installed)
   - Generate a random bearer token for this launch
   - Spawn the Python service as a subprocess with env vars:
     - `APP_SUPPORT_DIR` → Model storage location
     - `AICHAT_MODELS_DIR` → GGUF model directory
     - `AISERVER_TOKEN` → Bearer token for auth
   - Scan subprocess stdout for `http://127.0.0.1:<port>` or `http://localhost:<port>`
   - Broadcast the discovered URL via `MainApp.llmServiceUrl` (a BehaviorSubject)

5. **Register Scanners & Start Embedding Isolates**
   - `DatabaseManager.startBackgroundServices()` calls `ScannerManager.registerScanners()`
   - Scanners are registered **but not started**; sync is user-triggered (manual button, navigation)
   - Spawn `EmbeddingIsolate` (for files) and `EmailEmbeddingIsolate` (for emails)
   - Stagger isolate startup by ~500ms to avoid concurrent SQLite open contention

6. **Show Splash & Route**
   - Display splash screen during initialization
   - `AppRouter` redirects based on auth state:
     - **Not logged in** → Login page
     - **Logged in** → Home page (files, email, photos, or AI chat module)

Once the app is running, UI pages subscribe to `MainApp.llmServiceUrl` so they can start making HTTP calls to the Python service.

**Shutdown**: On app close, `windowManager.onWindowClose` triggers `pythonManager.stopAiServerService()`, which sends SIGTERM to the Python subprocess and waits up to 5 seconds before SIGKILL.

## Data Flow Example: File Collection Sync

Here's how a file collection (local filesystem or Google Drive) is discovered, scanned, and indexed:

```
1. User clicks "Add Collection" in Files module
   ↓
2. FileSourceRegistry detects source type (local / Google Drive)
   ↓
3. If cloud source → DesktopOAuthManager handles OAuth2 flow
   ↓
4. Collection metadata saved to SQLite via CollectionRepository
   ↓
5. ScannerManager.registerScanners() registers a scanner for this collection
   (No scan yet — registration-only)
   ↓
6. User navigates to collection or clicks "Sync" button
   ↓
7. Scanner.start(force: true) is called
   ↓
8. LocalFileIsolate or CloudFileIsolate spawns a background Isolate
   ↓
9. Scanner discovers files (recursive walk or API listing)
   ↓
10. Metadata extracted (EXIF, thumbnails, size, modified date)
    ↓
11. File upserts sent back to main isolate via scan_write_relay.dart
    (Ordered relay ensures folders arrive before their contents)
    ↓
12. Main isolate writes to SQLite via its single AppDatabase connection
    ↓
13. Scanner signals completion (scanner.isScanning: false)
    ↓
14. UI updates via RxFilesPage's RxService sink
    ↓
15. EmbeddingIsolate picks up newly-discovered files and generates vectors
    ↓
16. Vectors sent back to main isolate and stored in SQLite (file_embeddings table)
    ↓
17. Files now searchable via semantic search in AI Chat module
```

**Key invariant**: Only the main isolate writes to SQLite. Background isolates open read-only connections and relay writes back.

See [Isolates & Write Relay](./isolates.md) for details on the write-consistency pattern.

## Module Layout

Each feature (files, email, photos, AI chat) is a module under `client/lib/modules/<feature>/`:

```
modules/<feature>/
  pages/      # Screens (e.g., FilesPage, EmailPage)
  widgets/    # UI components
  services/   # Business logic (scanners, repositories, state)
```

Shared infrastructure lives in:

```
client/lib/
  repositories/       # Data access layer (resqlite queries)
  services/           # Cross-module services (rx_service base class, model download, auth, etc.)
  scanners/           # CollectionScanner interface + ScannerManager (lifecycle only)
  file_sources/       # OAuth providers (Google Drive, local FS)
  oauth/              # OAuth2 desktop flow
  models/tables/      # Database schema models (hand-written)
  pages/              # Top-level pages (Home, Login, Setup, Splash, Settings)
  widgets/            # Reusable widgets (buttons, modals, dialogs)
  database_manager.dart   # SQLite initialization & schema
  python_manager.dart     # Python subprocess management
  main.dart               # Global state (MainApp singletons, app entry)
```

## Core Patterns

### 1. Main Isolate Bottleneck for Consistency

Background isolates cannot write to SQLite directly. Embedding vectors, scanned files, and email messages are sent back to the main isolate via a **write-relay** mechanism (see [Isolates & Write Relay](./isolates.md)) for guaranteed ordering and consistency.

### 2. RxDart for State Management

Global state and page-level state use RxDart `BehaviorSubject` and `PublishSubject` streams:

```dart
// Global state (defined in main.dart)
static final llmServiceUrl = BehaviorSubject<String?>();
static final currentUser = BehaviorSubject<AppUser?>();

// Page-level state
class FilesPageState {
  final fileList = BehaviorSubject<List<File>>();
  final currentFolder = BehaviorSubject<Folder?>();
}

// Widgets subscribe to streams
fileList.listen((files) { setState(() { ... }); });
```

### 3. Hand-Written SQL with No Codegen

There is no Drift, no code generation. The schema is declared as raw SQL strings in `database_manager.dart`, and models are plain Dart classes with manual serialization:

```dart
class File {
  final int id;
  final String name;
  final int sizeBytes;
  
  File.fromMap(Map<String, Object?> map)
    : id = map['id'] as int,
      name = map['name'] as String,
      sizeBytes = map['size_bytes'] as int;
  
  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'size_bytes': sizeBytes,
  };
}
```

Schema changes require hand-editing both the DDL and the model. See [Database Design](./database.md) for the migration strategy.

### 4. Registration-Only Scanner Startup

`ScannerManager` registers scanners at app launch but does **not** trigger a sync. Users must manually trigger a sync:

- Navigating to a file collection
- Clicking a "Sync" or "Refresh" button
- Triggering a full-app rescan from settings

This avoids spinning up isolates, hammering the network, or blocking the UI on every app launch.

See [Scanning & Sync Lifecycle](../data-flow/scanning.md) for details.

## Python Service Communication

The Flutter client communicates with the bundled Python service over HTTP on localhost. All requests include a `Authorization: Bearer <token>` header for session isolation.

### Key Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `POST /v1/chat/completions` | POST | Chat completion (streaming or non-streaming); supports local GGUF or cloud passthrough |
| `POST /v1/chat/stop` | POST | Cancel an in-flight generation |
| `POST /util/embedding` | POST | Generate text or image embeddings (multimodal Qwen3-VL) |
| `GET /util/model-status` | GET | Check if a model is already downloaded |
| `POST /util/download-model` | POST | Download a GGUF or HF model (streaming SSE progress) |
| `POST /util/delete-model` | POST | Delete a downloaded model |
| `POST /util/import/pst` | POST | Stream-parse an Outlook PST file |
| `POST /util/thumbnail` | POST | Generate a thumbnail for an image (incl. RAW formats) |
| `GET /skills` | GET | List available `/command` skill definitions |

See `/aiserver/src/aichat/routes.py` for the full implementation.

## Next Steps

- **[Database Design](./database.md)** — SQLite schema, hand-written models, schema migration
- **[Isolates & Write Relay](./isolates.md)** — How background isolates maintain data consistency
- **[Scanning & Sync Lifecycle](../data-flow/scanning.md)** — File/email discovery and indexing
- **[State Management](../data-flow/state-management.md)** — RxDart patterns and data flow

## Source References

- **Startup & PythonManager**: `/client/lib/main.dart`, `/client/lib/python_manager.dart`
- **Scanner Registration**: `/client/lib/scanners/scanner_manager.dart`
- **Database Initialization**: `/client/lib/database_manager.dart`
- **Routes & Endpoints**: `/aiserver/src/aichat/routes.py`, `/aiserver/src/aichat/main.py`
