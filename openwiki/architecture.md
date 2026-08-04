# Architecture Overview

My Data Studio is a hybrid Flutter + Python application where the Python service (aiserver) is bundled as a subprocess, not a separate deployment. This page explains the overall design, startup sequence, data flow, and state management patterns.

---

## High-Level Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                   Flutter macOS Client (client/)              │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │ UI Layer (Pages & Widgets)                               │ │
│  │ - Pages: Home, Login, Setup, Splash                      │ │
│  │ - Modules: files, email, photos, aichat, social         │ │
│  │ - Adaptive UI with responsive layout                     │ │
│  └─────────────────────────┬────────────────────────────────┘ │
│                            │                                  │
│  ┌─────────────────────────▼────────────────────────────────┐ │
│  │ Service Layer (RxDart State Management)                  │ │
│  │ - RxService<C,R> pattern for all services               │ │
│  │ - Global app state: supportDirectory, llmServiceUrl     │ │
│  │ - Module-level services: PhotosService, EmailService    │ │
│  │ - Repositories: resqlite query layer                    │ │
│  └─────────────────────────┬────────────────────────────────┘ │
│                            │                                  │
│  ┌─────────────────────────▼────────────────────────────────┐ │
│  │ Data & Background Processing                            │ │
│  │ ┌──────────────────────────────────────────────────────┐ │ │
│  │ │ AppDatabase (resqlite + resqlite_vector)           │ │ │
│  │ │ - Main isolate: Read/Write access                  │ │ │
│  │ │ - Scanner isolates: Read-only + Write Relay       │ │ │
│  │ │ - Embedding isolates: Read-only + Write Relay     │ │ │
│  │ └──────────────────────────────────────────────────────┘ │ │
│  │                                                          │ │
│  │ ┌──────────────────────────────────────────────────────┐ │ │
│  │ │ Background Isolates (Parallel Processing)          │ │ │
│  │ │ - LocalFileIsolate (FS scanning + EXIF extraction) │ │ │
│  │ │ - CloudFileIsolate (Google Drive scanning)         │ │ │
│  │ │ - Email Scanner Isolates (Gmail, Outlook, Yahoo)  │ │ │
│  │ │ - EmbeddingIsolate (File embeddings)               │ │ │
│  │ │ - EmailEmbeddingIsolate (Email embeddings)         │ │ │
│  │ │ → All writes relayed to main isolate via port      │ │ │
│  │ └──────────────────────────────────────────────────────┘ │ │
│  │                                                          │ │
│  │ ┌──────────────────────────────────────────────────────┐ │ │
│  │ │ PythonManager                                      │ │ │
│  │ │ - Spawns aiserver subprocess on startup           │ │ │
│  │ │ - Discovers localhost:PORT from stdout            │ │ │
│  │ │ - Broadcasts URL via MainApp.llmServiceUrl         │ │ │
│  │ │ - Manages subprocess lifecycle (SIGTERM → KILL)   │ │ │
│  │ └──────────────────────────────────────────────────────┘ │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                               │
│                   HTTP + Bearer Token                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              aiserver (Python FastAPI subprocess)           │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ FastAPI / Uvicorn on localhost (random high port)    │ │
│  │ - Request validation (Pydantic models)                │ │
│  │ - Bearer token authentication                         │ │
│  │ - Error handling, logging                             │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Route Handlers (routes.py)                           │ │
│  │ POST /v1/chat/completions  — Chat w/ streaming      │ │
│  │ POST /v1/chat/stop         — Cancel generation       │ │
│  │ POST /util/embedding       — Text/image embeddings  │ │
│  │ GET /util/model-status     — Check downloaded status │ │
│  │ POST /util/download-model  — Download GGUF → SSE   │ │
│  │ POST /util/delete-model    — Remove downloaded model │ │
│  │ POST /util/thumbnail       — Generate thumbnails    │ │
│  │ POST /util/import/pst      — Parse Outlook PST      │ │
│  │ GET /skills                — List built-in commands  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Model Management (model_manager.py)                  │ │
│  │ - llama-cpp-python: Local GGUF inference (Gemma)    │ │
│  │ - Qwen3-VL: Multimodal embeddings                    │ │
│  │ - Cloud: LangChain wrappers (Gemini/Claude/OpenAI) │ │
│  │ - Model registry & caching                            │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ Utilities (utils.py, pst_parser.py, skills.py)      │ │
│  │ - HuggingFace model downloads                         │ │
│  │ - Archive handling (zip, tar)                         │ │
│  │ - PST parsing (pypff library)                         │ │
│  │ - Built-in chat skills (/command support)            │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                           │
            Local File System (Models, Cache)
```

---

## Startup Sequence

```
1. Initialize Flutter bindings & MediaKit initialization
2. Initialize window manager (desktop-specific)
3. Load user preferences (theme, window size, etc.)
4. Check database configuration
   → If not configured: show Setup page (user adds first source)
   → If configured: proceed

5. Initialize AppDatabase (resqlite + resqlite_vector) on main isolate
   - Load schema DDL from database_manager.dart
   - Run idempotent migrations (ALTER TABLE IF NOT EXISTS, etc.)

6. Initialize PythonManager:
   - Unzip bundled aiserver-<platform>.zip into Application Support
     (skipped if already installed at current version)
   - Generate per-launch bearer token (stored in MainApp.llmServiceToken)
   - Spawn aiserver subprocess:
     * Pass env vars: APP_SUPPORT_DIR, AICHAT_MODELS_DIR, AISERVER_TOKEN
     * Execute: aiserver/main.py
   - Scan subprocess stdout for "http://127.0.0.1:<port>" or "http://localhost:<port>"
   - Once found, publish URL via MainApp.llmServiceUrl (BehaviorSubject)

7. DatabaseManager.startBackgroundServices():
   - Register all scanners (registration-only, no scan yet)
   - Stagger isolate startup by ~500ms to avoid concurrent-open DB contention
   - Start EmbeddingIsolate (for files)
   - Start EmailEmbeddingIsolate (for emails, delayed by ~500ms)
   - Show splash screen → Main app

8. AppRouter redirects based on auth state:
   → Not logged in: Login page
   → Logged in: Home page (shows available collections and modules)
```

**Why the staggered startup?** SQLite connections are not cheap on first open. Staggering isolate startup by ~500ms avoids thundering-herd contention on the database connection pool.

---

## Data Flow: File Collection Example

A typical user workflow from collection creation to file search:

```
1. User adds collection
   ↓
2. Source detected (local filesystem or Google Drive)
   ↓
3. OAuth flow triggered (if cloud source)
   ↓
4. Collection saved to database (File.folders table)
   ↓
5. ScannerManager registers scanner isolate
   (registration-only, no scan yet; ScannerManager.start() called later)
   ↓
6. User navigates to Files page or manually triggers sync
   → RxFilesPage calls GetFilesAndFoldersService.invoke(command)
   → Service queries DB immediately → emits cached results → UI renders
   → Service also calls scanner.start(force: true) to begin background scan
   ↓
7. Scanner isolate spawns:
   ┌────────────────────────────────────────────┐
   │ LocalFileIsolate or CloudFileIsolate       │
   ├────────────────────────────────────────────┤
   │ Discovery Phase:                           │
   │ - Walk directory / list cloud items        │
   │ - Extract metadata (EXIF, thumbnails)     │
   │ - Build list of discovered files           │
   │                                            │
   │ Sync Phase:                                │
   │ - For each discovered file:                │
   │   - Call writeViaMain({type: 'dbWrite',   │
   │     action: 'insertFile', data: {...}})  │
   │   - Main isolate executes write           │
   │   - Emits scanner.isScanning = true       │
   │                                            │
   │ Final:                                     │
   │ - Emit scanner.isScanning = false         │
   └────────────────────────────────────────────┘
   ↓
8. Page subscribes to scanner.isScanning (BehaviorSubject<bool>)
   ↓
9. When scanner transitions true → false:
   - Page re-invokes GetFilesAndFoldersService for silent refresh
   - New results emitted to UI
   ↓
10. User queries (search / embedding-based similar files):
    - UI calls LocalLlmContentGenerator
    - HTTP POST /util/embedding (file content/metadata)
    - aiserver generates embeddings via Qwen3-VL
    - Flutter client inserts embeddings into resqlite_vector
    ↓
11. User searches semantic query:
    - UI calls LocalLlmContentGenerator /v1/chat/completions
    - Chat uses vector search results as context
    - Streaming response rendered in UI
```

---

## State Management: RxDart

The entire app uses **RxDart 0.28** for reactive state. There is **no Provider, Bloc, or Riverpod**.

### Core Pattern: `RxService<C, R>`

All business logic services inherit from `RxService<Command, Result>` defined in `client/lib/services/rx_service.dart`:

```dart
abstract class RxService<C extends RxCommand, R> {
  late BehaviorSubject<C> _source;
  late BehaviorSubject<R> _sink;
  late BehaviorSubject<bool> _isLoading;

  BehaviorSubject<C> get source => _source;
  BehaviorSubject<R> get sink => _sink;
  BehaviorSubject<bool> get isLoading => _isLoading;

  Future<R> invoke(C command) async => throw UnimplementedError();
}
```

**Usage Pattern:**

```dart
// 1. Create a service (singleton)
class MyService extends RxService<MyCommand, MyResult> {
  static final MyService _instance = MyService._();
  static MyService get instance => _instance;

  MyService._() {
    _source = BehaviorSubject<MyCommand>();
    _sink = BehaviorSubject<MyResult>();
    _isLoading = BehaviorSubject<bool>.seeded(false);
  }

  @override
  Future<MyResult> invoke(MyCommand command) async {
    isLoading.add(true);
    try {
      final result = await _doWork(command);
      sink.add(result);
      return result;
    } catch (e, st) {
      sink.addError(e, st);
      rethrow;
    } finally {
      isLoading.add(false);
    }
  }
}

// 2. Call from UI
await MyService.instance.invoke(MyCommand(data));

// 3. Subscribe to results
MyService.instance.sink.listen((result) {
  setState(() => _result = result);
});

// 4. Watch loading state
MyService.instance.isLoading.listen((loading) {
  setState(() => _isLoading = loading);
});
```

### Subject Types

| Type | Used For | Behavior |
|------|----------|----------|
| `BehaviorSubject<T>` | State that new subscribers need immediately | Replays last value on subscribe |
| `PublishSubject<T>` | One-time events (selection changes, navigation) | Only broadcasts future values |

### Global App State

Static `BehaviorSubject`s on `MainApp` (in `main.dart`) hold app-wide state:

```dart
class MainApp {
  // Directories
  static final BehaviorSubject<Directory?> supportDirectory = BehaviorSubject();
  static final BehaviorSubject<String?> appDataDirectory = BehaviorSubject();

  // LLM Service
  static final BehaviorSubject<String?> llmServiceUrl = BehaviorSubject();
  static final BehaviorSubject<String?> llmServiceToken = BehaviorSubject();
}
```

Any widget can access these globally:

```dart
MainApp.llmServiceUrl.value  // Get current value
MainApp.llmServiceUrl.listen((url) => ...)  // Subscribe to changes
```

### Page-Level State

Pages also define static `BehaviorSubject`s for cross-widget communication:

```dart
// In rx_files_page.dart
class RxFilesPage extends StatefulWidget {
  static PublishSubject<String> selectedCollection = PublishSubject();
  static BehaviorSubject<String> sortColumn = BehaviorSubject.seeded("name");
  static BehaviorSubject<bool> sortDirection = BehaviorSubject.seeded(true);
}

// Any child widget in the page tree can access
RxFilesPage.sortColumn.listen((column) => setState(() => _sortBy = column));
RxFilesPage.sortColumn.add("size");  // Notify all listeners
```

### Stream Subscription Lifecycle

**In `initState`:**

1. Create subscription(s)
2. For services that need to be invoked immediately, use `addPostFrameCallback` to avoid synchronous `BehaviorSubject` replay during first frame

```dart
@override
void initState() {
  super.initState();
  
  // Subscribe to results
  _sub = MyService.instance.sink.listen((result) {
    setState(() => _result = result);
  });
  
  // Invoke AFTER first frame to prevent early setState
  WidgetsBinding.instance.addPostFrameCallback((_) {
    MyService.instance.invoke(MyCommand());
  });
}
```

**In `dispose`:**

Always cancel subscriptions:

```dart
@override
void dispose() {
  _sub?.cancel();
  super.dispose();
}
```

### Background Scan → UI Update Flow

The files and email modules use a **cache-then-scan** pattern:

```
1. Service queries DB immediately
   ↓
2. Emits cached results to UI
   ↓
3. Service starts background scanner (fire-and-forget)
   ↓
4. Page subscribes to scanner.isScanning (BehaviorSubject<bool>)
   ↓
5. Scanner transitions true → false
   ↓
6. Page re-invokes service for silent refresh
   ↓
7. New results emitted, UI updates
```

This ensures responsive UI (immediate cache render) plus up-to-date data (async scan).

---

## Flutter → Python Communication

The client communicates with aiserver via HTTP with Bearer token authentication.

### Service Discovery

On startup, `PythonManager`:

1. Spawns aiserver subprocess with env vars: `APP_SUPPORT_DIR`, `AICHAT_MODELS_DIR`, `AISERVER_TOKEN`
2. Scans subprocess stdout for a URL pattern: `http://127.0.0.1:<port>` or `http://localhost:<port>`
3. Once found, publishes URL to `MainApp.llmServiceUrl` (BehaviorSubject)
4. All HTTP clients (like `LocalLlmContentGenerator`) subscribe to this URL

### Bearer Token

Every HTTP request includes:
```
Authorization: Bearer <AISERVER_TOKEN>
```

The token is generated per-app-launch by `PythonManager` and validated by aiserver's auth middleware.

### Key Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/v1/chat/completions` | Streaming or buffered chat completion (local GGUF or cloud provider passthrough) |
| `POST` | `/v1/chat/stop` | Cancel an in-flight generation |
| `POST` | `/util/embedding` | Generate text or image embeddings (local Qwen3-VL model) |
| `GET` | `/util/model-status` | Check whether a GGUF model is already downloaded on disk |
| `POST` | `/util/download-model` | Download a GGUF file or HuggingFace snapshot; streams SSE progress |
| `POST` | `/util/delete-model` | Delete a downloaded model from disk |
| `POST` | `/util/thumbnail` | Generate an image thumbnail (supports RAW, HEIC, JPEG, PNG, etc.) |
| `POST` | `/util/import/pst` | Stream-parse an Outlook PST file |
| `GET` | `/skills` | List built-in `/command` skills for chat |

See [Python Service](./python-service.md) for full request/response schemas and examples.

---

## Database Architecture

The app uses **SQLite** with **resqlite** (Rust bindings) and **resqlite_vector** (vector storage).

### Why Not Drift?

Drift is excellent for code-generated schemas, but My Data Studio prefers **hand-written schema control** to:
- Have full control over indices and performance
- Support custom migration logic without codegen complexity
- Integrate seamlessly with vector storage (resqlite_vector)

### Schema Definition

The entire schema is declared as raw DDL in `client/lib/database_manager.dart` (`AppDatabase.schemaDDL`):

```dart
const String schemaDDL = '''
  CREATE TABLE IF NOT EXISTS app_user (
    id TEXT PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );
  
  CREATE TABLE IF NOT EXISTS files (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    path TEXT UNIQUE NOT NULL,
    size INTEGER,
    mime_type TEXT,
    folder_id TEXT,
    is_favorite INTEGER DEFAULT 0,
    ... more columns
  );
  
  CREATE TABLE IF NOT EXISTS file_embeddings (
    id TEXT PRIMARY KEY,
    file_id TEXT NOT NULL UNIQUE,
    vector BLOB,
    FOREIGN KEY (file_id) REFERENCES files(id)
  );
  
  -- ... all other tables
''';
```

### Models

Corresponding Dart models under `models/tables/` are hand-written with `fromMap`/`toMap`:

```dart
class File {
  final String id;
  final String name;
  final String path;
  final int? size;
  final bool isFavorite;
  // ... more fields

  File({
    required this.id,
    required this.name,
    required this.path,
    this.size,
    this.isFavorite = false,
  });

  factory File.fromMap(Map<String, dynamic> map) {
    return File(
      id: map['id'],
      name: map['name'],
      path: map['path'],
      size: map['size'],
      isFavorite: map['is_favorite'] == 1,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'path': path,
    'size': size,
    'is_favorite': isFavorite ? 1 : 0,
  };
}
```

### Migrations

Schema changes are handled with idempotent migrations in `startBackgroundServices()`:

```dart
// Example migration: add is_favorite column if it doesn't exist
final userVersion = await database.pragmaUserVersion();
if (userVersion < 1) {
  await database.execute(
    'ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0'
  );
  await database.setPragmaUserVersion(1);
}
```

This approach ensures:
- Backwards compatibility (old app versions can still open newer schema)
- No codegen complexity
- Full control over indices and migration timing

---

## Isolate Communication: Write Relay Pattern

Background isolates (scanners, embedding generators) cannot write directly to the database due to SQLite connection affinity and contention. Instead, the **write relay pattern** is used:

### Design

1. **Main Isolate** — Owns the sole `AppDatabase` connection (read/write)
2. **Scanner/Embedding Isolate** — Opens read-only `AppDatabase` connection
3. **Write Message** — Isolate sends `{'type': 'dbWrite', ...}` over a `SendPort`
4. **Relay Handler** — Main isolate receives and executes the write

### Implementation

**In Scanner Isolate:**

```dart
// From scan_isolate_support.dart
Future<void> writeViaMain(Map<String, dynamic> dbWrite) async {
  // Send message to main isolate via port
  // Main isolate handles in scan_write_relay.dart handleScanWriteMessage()
  _mainSendPort.send({'type': 'dbWrite', 'data': dbWrite});
  
  // Wait for acknowledgment (30s timeout)
  await _writeAck.first;
}
```

**In Main Isolate:**

```dart
// From scan_write_relay.dart
void handleScanWriteMessage(Map<String, dynamic> message) {
  final action = message['data']['action'];  // e.g., 'insertFile'
  final data = message['data']['data'];
  
  // Execute write on main isolate's AppDatabase connection
  switch (action) {
    case 'insertFile':
      appDatabase.execute('''
        INSERT INTO files (...) VALUES (...)
      ''', [data['id'], data['name'], ...]);
      break;
    // ... other writes
  }
  
  // Send acknowledgment back to isolate
  _scannerPort.send({'ack': true});
}
```

### Why This Matters

1. **Serial Writes** — Only one write at a time on the main connection → no `SQLITE_BUSY` contention
2. **Visibility** — Writes immediately visible to all scanner connections (no stale cache)
3. **Atomicity** — All mutations on the main isolate connection ensure consistency
4. **Order Preservation** — For listener-based scanners (Gmail, Outlook), a `SequentialWriteQueue` ensures writes process in order

### Sequential Write Queue

Email scanners (Gmail, Outlook, Yahoo) use a `receivePort.listen(...)` callback pattern that doesn't naturally serialize writes. A `SequentialWriteQueue` on the main isolate ensures order:

```dart
// In main isolate
final writeQueue = SequentialWriteQueue(appDatabase);

// When email scanner sends write message
writeQueue.enqueue((db) async {
  await db.execute('INSERT INTO emails (...) VALUES (...)', [...]);
});

// Queue ensures previous write completes before next one starts
```

---

## Module Architecture

Each feature module follows the same pattern:

```
modules/<feature>/
  pages/           # Screens / routes
    <feature>_page.dart
    <feature>_detail_page.dart
    ...

  widgets/         # UI components
    <feature>_drawer.dart
    <feature>_table.dart
    <feature>_tile.dart
    ...

  services/        # Business logic (RxService subclasses)
    <feature>_service.dart
    <feature>_repository.dart
    scanners/      # Background isolate implementations (if any)
      <source>_isolate.dart
```

See [Modules](./modules.md) for details on each module.

---

## Error Handling & Logging

### Logging

`AppLogger` (`app_logger.dart`) broadcasts status messages:

```dart
// In main isolate
AppLogger.statusSubject.add("Starting file scan...");

// In isolate (via SendPort)
_logPort.send({'type': 'log', 'message': 'Processing file: foo.txt'});

// Listen in UI
AppLogger.statusSubject.listen((message) {
  setState(() => _status = message);
});
```

### Error Handling

RxService subclasses catch and emit errors:

```dart
@override
Future<List<File>> invoke(GetFilesCommand command) async {
  try {
    final files = await _repository.getFiles();
    sink.add(files);
    return files;
  } catch (e, st) {
    sink.addError(e, st);  // Emit error to subscribers
    rethrow;
  } finally {
    isLoading.add(false);
  }
}

// Subscribe and handle errors
MyService.instance.sink.listen(
  (result) => setState(() => _result = result),
  onError: (error) => _showErrorDialog(error),
);
```

---

## Next Steps

- See [Flutter Client](./flutter-client.md) for detailed module and repository structure
- See [Python Service](./python-service.md) for aiserver route details and model management
- See [Modules](./modules.md) for feature-specific architecture
- See [Data Models](./data-models.md) for database schema details
