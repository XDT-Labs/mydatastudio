# CRITICAL TOOL USE INSTRUCTIONS

## What This Is

My Data Studio Desktop is a local-first personal data archive & management tool, letting users view and search their local drives, cloud drives, email, photos, and social media entirely on-device. AI-powered search and chat use local LLMs by default; optionally, a user can supply their own API key to route requests through a cloud model (Gemini/Claude/OpenAI/Grok) instead, which sends that request off-device to the provider.

The app has two runtime components:
1. **Flutter macOS desktop client** (`client/`) — the UI and data layer
2. **Python FastAPI service** (`aiserver/`) — embedded in the Flutter app and spawned as a subprocess at startup, handles all LLM inference and embeddings over HTTP on localhost

## Development Practices

- **Test-driven for non-trivial changes**: write a test that expresses the intended behavior before implementing, then implement to make it pass (red-green-refactor). Trivial one-liners don't need ceremony — use judgment, consistent with Rule 2 below.
- **Build before test**: run a build and fix compiler/analyzer errors before running the test suite — don't let test failures mask build breaks.
- **Regression tests**: when fixing a bug, add a test that would have caught it, not just the fix itself (see Rule 9).
- **Code qualities**: concrete enough to be understood, abstract enough to change; expose the problem's domain in naming; high cohesion / loose coupling; single responsibility per method/class.
- **Git commits**: always get explicit user approval before committing — never commit unprompted.
- **Mermaid diagrams**: quote node labels that contain spaces, newlines, or special characters (`()`, `[]`, `{}`, etc.) to avoid syntax errors.

---

# Project Architecture Overview

This section summarizes the project's architecture, patterns, and implementation details. See `ARCHITECTURE.md` at the repo root for the full write-up with diagrams.

## 1. High-Level Architecture

The project is a Flutter desktop application designed for high-performance data management and AI integration, leveraging **Isolates** for multi-threaded execution to keep the UI responsive during resource-intensive tasks (file scanning, embedding generation).

### Core Components
- **Modules** (`client/lib/modules/`): feature-specific logic (`aichat`, `files`, `email`, `photos`, `social`), each with `pages/`, `widgets/`, `services/`.
- **Services**: business logic and external integrations (e.g. the Python AI service, via `PythonManager`).
- **Repositories** (`client/lib/repositories/`): resqlite query layer.
- **AppDatabase**: resqlite (+ resqlite_vector) wrapper handling persistence and per-isolate connections.

## 2. Module System & Scanners

### Module Structure
Each feature (e.g. `aichat`, `files`, `photos`, `email`) is isolated within its own directory under `lib/modules`, containing:
- `pages/`: UI entry points.
- `widgets/`: reusable components.
- `services/`: feature-specific logic (e.g. `LocalLlmContentGenerator`), including a `services/scanners/` subfolder for that module's `CollectionScanner` implementations.

### Scanning Logic (ScannerManager)
- **ScannerManager** (`client/lib/scanners/scanner_manager.dart`): lifecycle manager for scanners, registered per `Collection.scanner` value. Per the "Registration-Only Startup" rule, it registers scanners on app start but never triggers a background scan automatically — scans start only on explicit `force: true` (manual sync or folder navigation).
- **`CollectionScanner` interface** (`client/lib/scanners/collection_scanner.dart`): the contract all scanners implement (`isScanning`, `start()`, `stop()`, `moveToTrash()`).
- **Isolate-based scanning**: e.g. `LocalFileIsolate` spawns a background worker to traverse the filesystem — critical on desktop where scanning large trees would otherwise freeze the UI.
- **Implemented scanners**: local filesystem, Google Drive, Gmail, Yahoo, Outlook (live IMAP). Outlook PST is a one-time UI-triggered import isolate, not a registered scanner. Dropbox/OneDrive constants exist but are unimplemented. `social` (Facebook/Twitter/Instagram) is placeholder UI only, with no backing scanner.

## 3. Database Management & Concurrency

The database is **resqlite** (+ **resqlite_vector**), not Drift. Schema is hand-written `CREATE TABLE IF NOT EXISTS` DDL in `database_manager.dart` (`AppDatabase.schemaDDL`) — there is no code generation, and no incremental schema-version counter; one-off migrations are gated by ad-hoc `PRAGMA user_version` checks.

### Write Operations
Only the main isolate's `AppDatabase` connection writes. Scanner and embedding isolates each open their own `AppDatabase` connection too, but only to read — every write is relayed over the isolate's existing control port to the main isolate and executed there (`scan_write_relay.dart`'s `handleScanWriteMessage` for scanners, `embedding_message_handler.dart`'s `handleEmbeddingMessage` for the embedding isolates), via a shared `writeViaMain()` helper (`scan_isolate_support.dart`) with a bounded timeout. This replaced an earlier design where every isolate wrote through its own connection directly, which caused `SQLITE_BUSY` contention and could silently drop a write when one connection's insert wasn't yet visible to another's guard clause. `DatabaseManager.startBackgroundServices` still staggers isolate startup by ~500ms to avoid concurrent-open contention on connection creation itself, and embedding isolates pause automatically while any scanner is actively syncing.

### Read Operations
Performed on the main isolate via `AppDatabase`/repositories. UI pages subscribe to `RxService` sinks (`BehaviorSubject`s) and re-invoke queries after a scan completes, rather than using live DB-level streaming watchers.

## 4. Build & Native Integration

- **Makefile**: orchestrates the full build — `make models` (download GGUF models), `make build-python` (PyInstaller, Metal-enabled on macOS), `make build-client` (Flutter macOS release), `make notarize`. See `CLAUDE.md` for the full command reference.
- **Python integration**: `PythonManager` unzips the bundled `aiserver-<platform>.zip`, spawns it as a subprocess with a per-launch bearer token, and discovers its URL by scanning stdout — ensuring it's bundled and managed correctly within the macOS application sandbox.

---

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
