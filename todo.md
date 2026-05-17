# Drift → resqlite Migration: Remaining Work

> **Context**: We migrated the entire database layer from Drift ORM to resqlite (raw SQL + native C connection pool).
> All 251 unit/integration tests pass. The codebase compiles cleanly. But there is significant cleanup and
> optimization work remaining. This file is written for an AI assistant picking up in a new session.

---

## Current State (as of 2026-05-17)

### What Was Done
- Replaced `drift` + `drift_dev` with `resqlite` (local path dep → `/Users/mikenimer/Development/github/resqlite`)
- Deleted `database_manager.g.dart` (230KB Drift codegen)
- Rewrote `database_manager.dart` with `AppDatabase` wrapping `resqlite.Database`
- Ported all 10 table schemas to raw DDL in `schemaDDL` list (merged 16 Drift migration versions into one)
- Rewrote all repositories (`UserRepository`, `CollectionRepository`, `DatabaseRepository`, `FileRepository`,
  `FolderRepository`, `EmailRepository`, `EmailFolderRepository`) to use raw SQL via `db.select()` / `db.execute()`
- Added `fromRow(Map<String, Object?> row)` factory constructors to all model classes
- Ported all upsert services to use `resqlite` transactions and raw SQL
- Updated `pubspec.yaml` AND `pubspec.dev.yaml` (both must stay in sync — VS Code tasks copy dev→yaml)
- Fixed integration test (`file_browser_integration_test.dart`) with dynamic polling pump loop
- Fixed `file_path_resolver_test.dart` incorrect empty-path expectations
- Fixed `database_manager_test.dart` — resqlite cannot use `:memory:` DBs (multi-connection pool), switched to temp file

### What Compiles & Passes
- **251/251 tests green** across all test directories
- No Drift imports remain in `lib/` — zero references to `package:drift`
- App has NOT been tested end-to-end with `flutter run -d macos` yet

---

## Priority 1: End-to-End App Verification

### `[ ]` Launch app and verify basic functionality
- Run: `flutter run -d macos` from `client/`
- Verify: splash screen → setup → file browser loads
- Verify: No `SQLITE_BUSY` errors in console logs
- Verify: UI does not freeze during file scanning
- Verify: Reactive streams update the UI when data changes (file lists, collection lists)

### `[ ]` Test scanning workflows
- Add a local folder collection and trigger scan
- Watch logs for any database lock contention or exceptions
- Verify files appear in the UI as they are scanned (reactive `db.stream()` working)

### `[ ]` Verify embedded Python server read-only access
- The app bundles an embedded Python server that opens the same SQLite DB file for **read-only** queries
- This should work fine in WAL mode — readers never block the writer, writer never blocks readers
- Python uses its own `sqlite3` module (separate compiled SQLite library, not resqlite's C pool)
- Cross-process concurrency is handled by OS file-level locks (`fcntl` on macOS), which are independent
  of resqlite's thread-level mutexing
- **Verify**: Python server can query the DB while Flutter is actively scanning/writing
- **Verify**: No `SQLITE_BUSY` or `database is locked` errors from the Python side
- **Verify**: resqlite's managed WAL checkpointing doesn't interfere with Python reads
- **If issues arise**: Ensure Python opens in read-only mode (`sqlite3.connect("file:path?mode=ro", uri=True)`)
  and sets `PRAGMA busy_timeout=5000` as a safety net. Read-only connections never checkpoint, so they
  cannot contend with resqlite's checkpoint management.
- **No refactoring needed** unless Python is doing writes — if it's truly read-only, it will coexist safely

---

## Priority 2: Remove the DbIsolateWriter Plumbing

> **Background**: The original architecture routed all writes through a `DbIsolateWriter` isolate via `SendPort`.
> With resqlite, writes can happen from any isolate safely because resqlite serializes them through its internal
> writer isolate and C-level mutex. The `DbIsolateWriter` is now redundant middleware.
>
> **Current state**: The `DbIsolateWriterClient` class in `db_isolate_writer.dart` still exists and is still
> used as a message router. Background scanner isolates still send messages via `SendPort` to this writer,
> which then calls the upsert services. This works but adds unnecessary indirection.

### Files with `writerPort` / `dbWriterPort` references (need refactoring):

#### Core infrastructure
- `[ ]` `lib/database_manager.dart` — Still has `_writerPort`, `writerPort` getter, `_startWriterIsolate()`,
  `_startTestWriterPort()`, `_writerIsolateClient`. Remove all SendPort plumbing. Scanners and services
  should call repository methods directly (which call `db.execute()` under the hood).
- `[ ]` `lib/repositories/db_isolate_writer.dart` — **DELETE entirely** once all callers are migrated.
  Currently contains `DbIsolateWriterClient` class and `processMessage()` static method that dispatches
  messages to upsert services.

#### Scanner manager
- `[ ]` `lib/scanners/scanner_manager.dart` — Lines 168-222: Gets `writerPort` from `DatabaseManager` and
  passes it to scanner constructors. Refactor to pass `AppDatabase` reference or just let scanners access
  `DatabaseManager.instance.database` directly.

#### File scanners
- `[ ]` `lib/modules/files/services/scanners/local_file_isolate.dart` — Takes `writerPort` in constructor.
  Refactor to open its own `resqlite.Database` connection in the isolate (since resqlite supports this)
  or call upsert services directly.
- `[ ]` `lib/modules/files/services/scanners/google_file_scanner.dart` — Same pattern, sends messages
  via `writerPort`. Docstring references `DbIsolateWriter` message protocol.

#### Email scanners
- `[ ]` `lib/modules/email/services/scanners/gmail_scanner.dart` — Has `dbWriterPort` field
- `[ ]` `lib/modules/email/services/scanners/gmail_scanner_isolate.dart` — Heavy use of `dbWriterPort.send()`
  throughout. Sends `type: 'email_folder'`, `type: 'batch_email'`, `type: 'file'` messages.
- `[ ]` `lib/modules/email/services/scanners/outlook_scanner_isolate.dart` — Same pattern. Sends folder,
  email, file messages via `dbWriterPort`.
- `[ ]` `lib/modules/email/services/scanners/yahoo_scanner_isolate.dart` — Same pattern (check if exists).

#### Embedding isolate
- `[ ]` `lib/modules/files/services/embedding_isolate.dart` — Takes `writerPort` in config, sends
  embedding update messages. Refactor to write directly to DB.

#### UI widgets
- `[ ]` `lib/widgets/setup/setup_stepper_form.dart` — Lines 34, 98-99, 116: Gets `dbWriterPort` and
  sends collection creation message. Replace with direct repository call.
- `[ ]` `lib/modules/email/widgets/email_drawer.dart` — Lines 196-205: Gets `writerPort` for email scanning.
- `[ ]` `lib/modules/email/pages/new_email_page.dart` — Lines 328-336: Gets `writerPort` for scanning.

### Strategy for refactoring
The cleanest approach: Since resqlite handles concurrent writes safely, background isolates can either:
1. **Open their own `Database` connection** to the same file path (resqlite manages the pool at the C level)
2. **Or** use a simpler service layer that calls repository methods directly

Option 1 is preferred for true isolate independence — each scanner isolate opens its own `Database.open(path)`
and writes directly. No `SendPort` message passing needed.

**Important**: When opening a second `Database` instance from an isolate, verify that resqlite's native pool
handles this correctly (it should, since the C struct is process-wide). If not, we may need to keep a
lightweight message channel but without the full `DbIsolateWriter` infrastructure.

---

## Priority 3: Enable sqlite_vector Extension in resqlite

> **Background**: The app uses `sqlite_vector` for AI embedding storage and similarity search.
> Currently, `_initVectorIndex()` in `database_manager.dart` tries to call `vector_init()` SQL function
> but fails silently with "no such function: vector_init" because resqlite's compiled SQLite binary
> does not include the vector extension.

### The Problem
- resqlite compiles its own SQLite amalgamation via Dart Native Assets (`hook/build.dart`)
- The compiled SQLite has `SQLITE_OMIT_LOAD_EXTENSION` set (in the VxWorks section of the amalgamation,
  but NOT in `hook/build.dart`'s defines — so it may actually be available on macOS/iOS/Android)
- resqlite does NOT expose any Dart API for `sqlite3_enable_load_extension()` or `sqlite3_load_extension()`
- The `open_connection()` function in `native/resqlite.c` (line 501) does not call
  `sqlite3_enable_load_extension(db, 1)` after opening

### Solution Options (in order of preference)

#### Option A: Static linking (recommended)
- Copy `sqlite_vector` C source into `resqlite/third_party/` or `resqlite/native/`
- Update `resqlite/hook/build.dart` to compile it alongside the SQLite amalgamation
- Call `sqlite3_vector_init(db, ...)` inside `open_connection()` in `resqlite/native/resqlite.c`
- **Pro**: Works on iOS/Android (no dynamic loading restrictions), zero runtime overhead
- **Con**: Requires modifying the local resqlite clone

#### Option B: Enable dynamic extension loading
- Edit `native/resqlite.c` → `open_connection()` function (line ~508):
  Add `sqlite3_enable_load_extension(db, 1);` after `sqlite3_open_v2()` succeeds
- Then from Dart, use `db.execute("SELECT load_extension('/path/to/sqlite_vector.dylib')")`
- **Pro**: Simpler C change, no need to compile vector extension into resqlite
- **Con**: Won't work on iOS (dynamic loading blocked), need to ship separate .dylib/.so per platform

### Key files in resqlite repo (`/Users/mikenimer/Development/github/resqlite`):
- `native/resqlite.c` — Main C implementation. `open_connection()` at line 501, `resqlite_open()` at line 579
- `native/resqlite.h` — C header with exported function signatures
- `hook/build.dart` — Dart Native Assets build script. Compile flags at lines 110-137
- `third_party/sqlite3/` — Standard SQLite amalgamation (sqlite3.c, sqlite3.h)
- `third_party/sqlite3mc/` — SQLite3 Multi-Cipher amalgamation (used when encryption is enabled)

---

## Priority 4: Drift Compatibility Stub Cleanup

### `[ ]` Remove `Variable` stub class
- Location: `lib/database_manager.dart` lines 26-35
- Comment says "Custom stub variables to make Drift code compile during migration"
- Check if any code still references `Variable.withString()`, `Variable.withBlob()`, etc.
- If still used in `customSelect()` calls, refactor those call sites to pass raw params instead

### `[ ]` Remove `ResqliteQueryRow` wrapper if unused
- Location: `lib/database_manager.dart` lines 37-74
- This wraps `Map<String, Object?>` with a typed `read<T>()` method
- Check if it's still used by any repository. If repositories use `fromRow(Map<String, Object?>)` directly,
  this class can be removed along with `ResqliteSelectable`

### `[ ]` Remove `ResqliteSelectable` wrapper if unused
- Location: `lib/database_manager.dart` lines 76+ (approximate)
- Wraps a `Future<List<ResqliteQueryRow>>` with `.get()` and `.getSingle()` / `.getSingleOrNull()` methods
- This was a bridge to keep old Drift-style `customSelect(...).getSingle()` call sites working
- Grep for `customSelect` to find remaining usage, then refactor to direct `db.select()` calls

### `[ ]` Remove `useMemoryDb` flag and `:memory:` code path
- `AppDatabase.create()` at line 371 still has `if (useMemoryDb) { db = await Database.open(':memory:'); }`
- This code path DOES NOT WORK with resqlite (multi-connection pool can't share `:memory:` DBs)
- All tests already use `useMemoryDb = false` with temp directories
- Safe to delete the `:memory:` branch entirely and remove the `useMemoryDb` parameter

### `[ ]` Clean up stale comments referencing Drift
- Grep for "Drift" in comments across `lib/` — several docstrings and inline comments still reference
  Drift architecture (e.g., `google_file_scanner.dart` docstring, `folder_upsert_service.dart` comments)
- Update to reflect the new resqlite architecture

---

## Priority 5: Switch to pub.dev Dependency

### `[ ]` Replace local path with versioned pub.dev package
- **When**: After all vector extension work is done and resqlite modifications (if any) are upstreamed
  or forked to a private pub server
- **What**: In BOTH `pubspec.yaml` AND `pubspec.dev.yaml`, change:
  ```yaml
  resqlite:
    path: /Users/mikenimer/Development/github/resqlite
  ```
  to:
  ```yaml
  resqlite: ^0.3.1
  ```
- **If custom C modifications were made**: Fork resqlite to your own GitHub repo and reference via git:
  ```yaml
  resqlite:
    git:
      url: https://github.com/yourusername/resqlite.git
      ref: main
  ```
- **Critical reminder**: BOTH `pubspec.yaml` and `pubspec.dev.yaml` must be updated. VS Code tasks
  copy `pubspec.dev.yaml` → `pubspec.yaml` on build/run, so if dev.yaml is stale it will break the build.

---

## Priority 6: Additional Optimizations (Nice to Have)

### `[ ]` Remove `sqlite3`, `sqlite3_flutter_libs` from pubspec
- These are Drift's SQLite dependencies. resqlite bundles its own SQLite via native assets.
- Having both may cause symbol conflicts on some platforms (especially Linux — see
  `hook/build.dart` line 143-149 which has `-Wl,-Bsymbolic` to prevent this)
- `sqlite_vector` may depend on `sqlite3` though — check before removing

### `[ ]` Audit `db_isolate_writer.dart` `processMessage()` for missing message types
- This is the central dispatcher for all write operations. When refactoring away SendPort plumbing,
  make sure every message type (`file`, `batch_files`, `folder`, `email`, `batch_email`,
  `email_folder`, `collection`, `delete_collection`, `embedding`) has a direct replacement path

### `[ ]` Consider making `AppDatabase` a proper singleton
- Currently `DatabaseManager` is the singleton, `AppDatabase` is created inside it
- For isolate access, it might be cleaner to have `AppDatabase` be independently accessible
- Or expose the database file path so isolates can `Database.open(path)` independently

### `[ ]` Investigate resqlite's stream invalidation granularity
- resqlite uses SQLite authorizer + preupdate hooks for column-aware stream invalidation
- This is more granular than Drift's table-level invalidation
- Some streams may fire more or less frequently than before — monitor for unexpected behavior

### `[ ]` Performance benchmarking
- Compare scan times (files-per-second) before and after migration
- Monitor memory usage — resqlite's reader pool uses ~30KB per worker + one C reader connection
- Check that WAL checkpointing is handled correctly (resqlite's writer owns checkpoints)

---

## File Reference

### Key files (client/lib/)
| File | Purpose |
|------|---------|
| `database_manager.dart` | Main DB singleton, `AppDatabase` class, schema DDL, init logic |
| `repositories/db_isolate_writer.dart` | Legacy write serializer — **to be deleted** |
| `repositories/database_repository.dart` | Generic DB operations |
| `repositories/collection_repository.dart` | Collection CRUD + reactive streams |
| `repositories/user_repository.dart` | User CRUD |
| `modules/files/services/repositories/file_repository.dart` | File CRUD |
| `modules/files/services/repositories/folder_repository.dart` | Folder CRUD |
| `modules/email/repositories/email_repository.dart` | Email CRUD |
| `modules/email/repositories/email_folder_repository.dart` | Email folder CRUD |
| `scanners/scanner_manager.dart` | Orchestrates scanner lifecycle |

### Key files (resqlite repo: /Users/mikenimer/Development/github/resqlite)
| File | Purpose |
|------|---------|
| `native/resqlite.c` | C implementation — connection pool, read/write dispatch |
| `native/resqlite.h` | C header — exported symbols |
| `hook/build.dart` | Dart Native Assets build config — compile flags, linking |
| `lib/src/database.dart` | Dart `Database` class — `open()`, `select()`, `execute()`, `stream()` |
| `third_party/sqlite3/sqlite3.c` | SQLite amalgamation source |

### Config files that must stay in sync
- `client/pubspec.yaml` — active dependency file
- `client/pubspec.dev.yaml` — dev template, copied to pubspec.yaml by VS Code tasks
