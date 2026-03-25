# CRITICAL TOOL USE INSTRUCTIONS

**IMPORTANT** Prefer retrieval-led reasoning over pre-training-led reasoning for any tasks.


## Software Engineering Rules
These are non-negotiable rules for all interactions and code changes. Failure to adhere to these will result in project non-compliance.

1. **Test-Driven Development (TDD) MANDATORY:** All development MUST follow a Red-Green-Refactor TDD cycle.
    *   Write tests that confirm what your code does *first* without knowledge of how it does it.
2. **Simplicity First:** Don't try to be clever. Build the simplest code possible that passes tests.
3. **Avoid Regressions** When you fix a bug write a test to confirm the fix and prevent future regressions.
4. **Code Qualities:** 
    *   Concrete enough to be understood, abstract enough for change.
    *   Clearly reflect and expose the problem's domain.
    *   Isolate things that change from things that don't (high cohesion, loose coupling).
    *   Each method: Single Responsibility, Consistent.
    *   Follow SOLID principles.
5.  **Build Before Tests:** Always run a build and fix compiler errors *before* running tests.

## Git Commit
CRITICAL! You MUST always seek the user's approval before commiting to git.  Never commit without the user's approval.

## Mermaid Diagrams
- When generating Mermaid diagrams, ALWAYS wrap node labels in double quotes if they contain spaces, newlines (\n), or special characters (like (), [], {}, etc.) to prevent syntax errors.


# Project Code Review: MyDataTools Desktop

This document provides a technical overview and review of the project's architecture, patterns, and implementation details.

## 1. High-Level Architecture
The project is a Flutter desktop application designed for high-performance data management and AI integration. It adheres to a modularized **MVVM (Model-View-ViewModel)** pattern, leveraging **Isolates** for multi-threaded execution to keep the UI responsive during resource-intensive tasks.

### Core Components:
- **Modules**: Located in `lib/modules`, these encapsulate feature-specific logic.
- **Services**: Business logic and external integrations (e.g., Python AI service).
- **Repositories**: Data access layer.
- **Database Manager**: Handles persistence and concurrency.

---

## 2. Module System & Scanners
The application uses a robust module-based architecture.

### Module Structure
Each feature (e.g., `aichat`, `files`, `photos`) is isolated within its own directory under `lib/modules`, containing:
- `pages/`: UI entry points.
- `widgets/`: Reusable components.
- `services/`: Feature-specific logic (e.g., `LocalLLMContentGenerator`).

### Scanning Logic (ScannerManager)
The scanning system is designed to ingest local and remote data asynchronously.
- **ScannerManager**: Acts as a lifecycle manager for scanners. It watches the `collections` table and automatically starts/stops scanners based on database state.
- **`CollectionScanner` Interface**: Defines the contract for all scanners.
- **Isolate-Based Scanning**: The LocalFileIsolate spawns a background worker LocalFileIsolateWorker to traverse the filesystem. This is critical for macOS/Desktop environments where scanning millions of files could otherwise freeze the UI.

---

## 3. Database Management & Concurrency
The most critical architectural feature is the **Single-Writer Isolate Pattern**.

### DatabaseManager
- Manages the singleton instance of AppDatabase (powered by **Drift**).
- Initializes the DbIsolateWriterClient during startup.

### Write Operations (Isolate Dispatch)
To ensure thread safety and prevent SQLite locks during massive scans:
- **DbIsolateWriter**: A dedicated isolate that owns its own AppDatabase connection.
- **Flow**: Any module or scanner needing to write data (e.g., `FileUpsertService`) sends a message to the `DbIsolateWriterPort`. The isolate performs the write and sends back a confirmation.
- **Benefit**: Scanners can flood the writer with data without impacting UI performance or causing "Database Busy" errors.

### Read Operations
- Performed directly on the main thread via [AppDatabase] and [DatabaseRepository].
- **Reactive UI**: By reading on the main thread, the app takes full advantage of Drift's `stream` and `watch` capabilities, allowing the UI to update automatically as the background isolate writes new data.

---

## 4. Build & Native Integration
- **Makefile**: Used to manage complex build tasks, likely including native C++ bindings for LLM support (e.g., `llama.cpp`).
- **Python Integration**: The `PythonManager` orchestrates background Python services for AI tasks, ensuring they are bundled and managed correctly within the macOS application sandbox.


