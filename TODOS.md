# TODOS

## Testing

- **[P0] Fix sqlite_vector extension not loading in Flutter test runner**
  **Priority:** P0
  **What:** 27 database/repository tests fail with `SqliteException: no such function: vector_init`. The `sqlite_vector` native extension is not available in the headless Flutter test runner.
  **Why:** Blocks full test suite from running. 112/140 tests pass but the repository layer is untested in CI.
  **Error:** `SELECT vector_init('files_embeddings', 'qwen3_8b_embedding', 'type=FLOAT32,dimension=2048')` — function not loaded.
  **Affected tests:** All `test/repositories/database_repository_*_test.dart` and `test/database_manager_test.dart`.
  **Fix direction:** Load `sqlite_vector` dynamic library in test setUp, or mock the vector index initialization for the test database. See `DatabaseManager._initVectorIndex`.
  **Noticed on:** `feature/widgets` branch, 2026-03-27. Pre-existing on `main`.

## Completed

