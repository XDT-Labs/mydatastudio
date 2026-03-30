# Global Research Report: mydatatools-desktop

## Overview
`mydatatools-desktop` is a hybrid local-first application designed for privacy-centric data management and AI-assisted search and analysis. It integrates a Flutter frontend with a bundled Python-based AI service.

## Architectural Components

### 1. Flutter Client (UI & Orchestration)
- **Framework**: Flutter (Dart)
- **State Management**: Reactive pattern using RxDart (`RxService`).
- **Data Persistence**: Drift (SQLite) with `sqlite_vector` for semantic search.
- **Background Processing**: Dart Isolates are heavily used for file scanning, DB writes, and thumbnail generation to ensure UI responsiveness.
- **Key Files**:
    - `client/lib/main.dart`: Application entry point.
    - `client/lib/python_manager.dart`: Manages the lifecycle of the local Python service.
    - `client/lib/database_manager.dart`: Manages SQLite/Drift database and vector indexing.

### 2. Python AI Service (Local Inference)
- **Framework**: FastAPI (bundled with the application).
- **Core Models**:
    - Gemma 3.4B via `llama-cpp-python` for local LLM inference.
    - SigLip2 for embedding generation (multimodal search).
- **Communication**: Local HTTP requests from the Flutter client to the FastAPI service.
- **Key Files**:
    - `client/assets/python/aichat/src/aichat/main.py`: Entry point for the AI service.

### 3. Key Modules (Modules Pattern)
The application is organized into several key modules located in `client/lib/modules/`:
- **`files`**: Management of local and cloud (Google Drive) files.
- **`email`**: Archive and search for PST, Gmail, Yahoo, etc.
- **`aichat`**: Semantic search and chat interface using the local LLM.
- **`photos`**: Gallery, timeline view, and image analysis.

## Core Patterns

### Cache-then-Scan
The application uses a pattern where scanners (Local, Google Drive, Email) first populate the database ("cache"), and the UI reacts to these changes via Dart streams.

### Vector Search
The database includes specialized initialization for vector search via the `sqlite_vector` extension, enabling semantic similarity queries across stored data.

## Relevant Locations
- `ARCHITECTURE.md`: Foundational design documentation.
- `client/lib/services/rx_service.dart`: Core reactive service base class.
- `client/lib/python_manager.dart`: Logic for starting/stopping the AI service.
- `client/lib/database_manager.dart`: Database schema and vector index management.
- `client/assets/python/aichat/src/aichat/main.py`: AI service REST endpoints.
