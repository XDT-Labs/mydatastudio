# Testing Guide

MyDataStudio has comprehensive test coverage across both Flutter (Dart) and Python components. The test suite includes unit tests, integration tests, and end-to-end tests.

## Test Structure

### Flutter Tests (`/client/test/`)

Organized by feature module and functional area:

```
test/
  app_logger_test.dart
  credential_codec_test.dart
  custom_path_provider_test.dart
  database_manager_test.dart
  login_test.dart
  python_manager_test.dart
  secure_vault_test.dart
  theme_test.dart
  vault_manager_test.dart
  widget_test.dart
  
  encryption/
    key_generation_test.dart
  
  file_sources/
    file_source_file_test.dart
    file_source_registry_test.dart
    google_auth_service_test.dart
    google_drive_provider_test.dart
    local_file_provider_test.dart
  
  helpers/
    email_fixture.dart
    file_fixture.dart
    [test fixtures and helper data]
  
  integration/
    file_browser_integration_test.dart
  
  modules/
    aichat/
      aichat_page_test.dart
      [aichat-specific tests]
    
    email/
      email_decoding_helper_test.dart
      email_embedding_isolate_test.dart
      email_folder_repository_test.dart
      gmail/gmail_scanner_test.dart
      outlook/outlook_scanner_test.dart
      [email module tests]
    
    files/
      local_file_scanner_test.dart
      pages/new_file_collection_page_test.dart
      services/file_description_isolate_test.dart
      widgets/[widget tests]
    
    photos/
      photos_repository_test.dart
      pages/album_detail_page_test.dart
      pages/photos_app_test.dart
      services/batch_action_service_test.dart
      services/photos_service_test.dart
      services/selection_service_test.dart
      services/view_state_service_test.dart
      widgets/[widget tests]
  
  oauth/
    google_user_profile_test.dart
    json_accepting_http_client_test.dart
  
  pages/
    settings_test.dart
  
  repositories/
    database_repository_test.dart
    delete_artifacts_test.dart
    file_upsert_thumbnail_test.dart
  
  scanners/
    embedding_pause_resume_test.dart
    individual_scanners_test.dart
    local_file_isolate_queue_test.dart
    outlook_pst_scanner_isolate_test.dart
    scan_isolate_support_test.dart
    scanner_manager_sync_test.dart
  
  services/
    get_collections_service_test.dart
    sqlite_retry_test.dart
    update_checker_test.dart
```

**Total**: 100+ test files covering:

- Database operations and schema migrations
- OAuth flows (Google, Yahoo)
- File scanning (local filesystem, Google Drive)
- Email scanning (Gmail, Outlook IMAP, PST import)
- Embedding generation and vector search
- Photo gallery features (grid, timeline, map views)
- State management (RxService, BehaviorSubject)
- Widgets (UI components)
- Integration tests (end-to-end workflows)

### Python Tests (`/aiserver/tests/`)

```
tests/
  __init__.py
  conftest.py          # pytest fixtures, mocks, test database
  test_auth.py         # Bearer token validation
  test_fix_nonetype.py # Type handling
  test_model_manager.py # Model loading, inference
  test_path_confinement.py # Path traversal security
  test_routes.py       # HTTP endpoint tests
  test_start_session.py # Session management
  test_state.py        # Global service state
  test_thumbnail.py    # Image thumbnail generation
  test_utils.py        # Utility functions

src/aichat/
  tests/
    test_pst_parser.py  # Outlook PST parsing
    fixtures/
      aspose_sample.pst  # Sample PST file for testing
      outlook_sample.pst # Another sample PST
```

**Total**: 11 test modules covering:

- Authentication & bearer token validation
- FastAPI route handlers (chat, embeddings, models, skills)
- Model manager (loading GGUF, inference)
- PST file parsing (Outlook import)
- Thumbnail generation (image processing)
- Path confinement security (preventing directory traversal attacks)

## Running Tests

### Flutter Tests

```bash
cd client
flutter test                              # Run all tests
flutter test --coverage                  # Run with coverage report
flutter test test/modules/email/         # Run specific directory
flutter test test/modules/email/gmail/gmail_scanner_test.dart  # Specific file
flutter test -k "scanner"                # Run tests matching pattern
```

**Coverage**: After running with `--coverage`, view the HTML report:

```bash
cd client
flutter test --coverage
# View coverage at: coverage/lcov.html (open in browser)
```

### Python Tests

```bash
cd aiserver
pdm install                              # Install dev dependencies
PYTHONPATH=src pdm run pytest            # Run all tests
PYTHONPATH=src pdm run pytest -v         # Verbose output
PYTHONPATH=src pdm run pytest -s         # Show print statements
PYTHONPATH=src pdm run pytest --cov=src/aichat tests/  # With coverage
```

**Coverage**: After running with `--cov`, view the terminal report or generate HTML:

```bash
PYTHONPATH=src pdm run pytest --cov=src/aichat --cov-report=html tests/
# View coverage at: htmlcov/index.html
```

### Running Specific Tests

**Flutter**:

```bash
# Email scanner tests
flutter test test/modules/email/gmail/gmail_scanner_test.dart

# Database repository tests
flutter test test/repositories/database_repository_test.dart

# Isolate tests
flutter test test/scanners/local_file_isolate_queue_test.dart
```

**Python**:

```bash
# Chat completion endpoint
PYTHONPATH=src pdm run pytest tests/test_routes.py::test_chat_completion -v

# Model manager
PYTHONPATH=src pdm run pytest tests/test_model_manager.py -v

# PST parsing
PYTHONPATH=src pdm run pytest src/aichat/tests/test_pst_parser.py -v
```

## Test Categories

### Unit Tests

Test individual functions/classes in isolation:

- `credential_codec_test.dart` — Encryption/decryption helpers
- `email_decoding_helper_test.dart` — MIME parsing
- `test_utils.py` — Utility functions
- `test_thumbnail.py` — Image thumbnail generation

### Repository & Database Tests

Test data access layer:

- `database_repository_test.dart` — SQLite CRUD operations
- `email_folder_repository_test.dart` — Email folder queries
- `photos_repository_test.dart` — Photo queries
- `file_upsert_thumbnail_test.dart` — Thumbnail caching

### Service Tests

Test business logic:

- `photos_service_test.dart` — Photo filtering, sorting
- `batch_action_service_test.dart` — Bulk operations
- `selection_service_test.dart` — Multi-select state
- `test_model_manager.py` — Model loading, inference

### Scanner Tests

Test background isolates:

- `local_file_isolate_queue_test.dart` — File scanning from disk
- `gmail_scanner_test.dart` — Gmail IMAP sync
- `outlook_scanner_test.dart` — Outlook IMAP sync
- `outlook_pst_scanner_isolate_test.dart` — PST import
- `test_pst_parser.py` — PST parsing (Python side)

### Widget Tests

Test UI components:

- `photo_grid_tile_test.dart` — Photo grid tile rendering
- `email_table_test.dart` — Email list UI
- `file_drawer_test.dart` — File browser sidebar
- `info_sidebar_test.dart` — Photo metadata sidebar

### Integration Tests

Test end-to-end workflows:

- `file_browser_integration_test.dart` — Full file discovery & display workflow
- `embedding_pause_resume_test.dart` — Embedding isolate pause during scan
- `scanner_manager_sync_test.dart` — Collection sync lifecycle

### Route/Endpoint Tests (Python)

Test HTTP API:

- `test_routes.py::test_chat_completion` — Chat endpoint
- `test_routes.py::test_embedding` — Embedding endpoint
- `test_routes.py::test_model_status` — Model status endpoint
- `test_routes.py::test_download_model` — Model download endpoint

## Test Fixtures & Mocks

### Flutter Fixtures

Located in `/client/test/helpers/`:

- `email_fixture.dart` — Sample email messages (Gmail, Outlook, Yahoo)
- `file_fixture.dart` — Sample file objects (images, documents, etc.)

Usage:

```dart
import 'helpers/file_fixture.dart';

test('File upsert creates correct record', () {
  final file = fileFixture();
  final map = file.toMap();
  expect(map['name'], 'sample-image.jpg');
  expect(map['size_bytes'], 1024000);
});
```

### Python Fixtures

Located in `/aiserver/tests/conftest.py`:

```python
import pytest

@pytest.fixture
def sample_message():
  """Sample email message for testing."""
  return {
    'subject': 'Test Email',
    'from_address': 'test@example.com',
    'to_address': 'user@example.com',
    'body_text': 'This is a test.',
  }

@pytest.fixture
def mock_db(monkeypatch):
  """Mock SQLite database."""
  # Setup mock...
  return mock_db
```

Usage:

```python
def test_upsert_email(sample_message, mock_db):
  result = upsert_email(sample_message, mock_db)
  assert result['id'] > 0
```

### Mock HTTP Clients

For testing without real network calls:

**Flutter**:

```dart
import 'package:mockito/mockito.dart';

class MockHttpClient extends Mock implements http.Client {}

test('Chat completion streams tokens', () async {
  final mockHttp = MockHttpClient();
  when(mockHttp.post(...)).thenAnswer((_) async => http.Response(...));
  
  final generator = LocalLlmContentGenerator(client: mockHttp);
  final stream = generator.generate('Hello');
  expect(stream, emits('Hello'));
});
```

**Python**:

```python
from unittest.mock import patch

def test_chat_with_mock_model():
  with patch('aichat.model_manager.load_model') as mock_load:
    mock_load.return_value = MockLLM()
    response = chat_completion(...)
    assert response['choices'][0]['message']['content'] == '...'
```

## Continuous Integration (CI)

GitHub Actions workflows in `/.github/workflows/`:

### `build_and_release.yml`

Runs on every push:

1. **Build Flutter client** (`flutter build macos`)
2. **Build Python service** (`make build-python`)
3. **Run Flutter tests** (`flutter test`)
4. **Run Python tests** (`PYTHONPATH=src pdm run pytest`)

On release tags, also:

5. **Notarize macOS app** (requires secrets)
6. **Upload to release** (GitHub Releases)

### `build_python.yml`

Runs on every push to Python-related files:

1. **Install Python 3.11–3.14**
2. **Install pdm dependencies**
3. **Run Python tests**
4. **Build Python binary**

## Test Coverage Goals

- **Flutter**: Aim for 80%+ coverage on business logic; UI tests are coarser-grained
- **Python**: Aim for 90%+ coverage on routes and model manager

Current approximate coverage:

```
Flutter:
  ├─ Repositories: 85%
  ├─ Services: 80%
  ├─ Scanners: 75%
  └─ Widgets: 60%

Python:
  ├─ Routes: 90%
  ├─ Model Manager: 85%
  ├─ Auth: 95%
  └─ PST Parser: 70%
```

## Debugging Test Failures

### Flutter

**Test hangs or times out**:

```bash
flutter test --timeout=30s test/scanners/local_file_isolate_queue_test.dart
```

**Verbose output**:

```bash
flutter test -v test/modules/email/gmail/gmail_scanner_test.dart
```

**Print statements in test**:

```dart
test('Something', () {
  print('Debug: file = ${file.name}');
  expect(file.name, 'expected.txt');
});
```

Run with: `flutter test -s` (show print output)

### Python

**Verbose pytest output**:

```bash
PYTHONPATH=src pdm run pytest tests/test_routes.py::test_chat_completion -vv
```

**Print statements**:

```bash
PYTHONPATH=src pdm run pytest -s tests/test_routes.py
```

**Stop at first failure**:

```bash
PYTHONPATH=src pdm run pytest -x tests/
```

**Drop into debugger on failure**:

```bash
PYTHONPATH=src pdm run pytest --pdb tests/test_routes.py
```

## Writing New Tests

### Flutter Test Template

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'helpers/file_fixture.dart';

void main() {
  group('FileRepository', () {
    late FileRepository repo;
    
    setUpAll(() {
      // One-time setup
    });
    
    setUp(() {
      // Before each test
      repo = FileRepository(db);
    });
    
    tearDown(() {
      // After each test
    });
    
    test('upsertFile creates new record', () async {
      final file = fileFixture();
      await repo.upsertFile(file);
      final fetched = await repo.getFile(file.id);
      expect(fetched.name, file.name);
    });
    
    test('getFilesInFolder returns sorted results', () async {
      final folder = await repo.createFolder(...);
      // ... add files ...
      final files = await repo.getFilesInFolder(folder.id);
      expect(files, isNotEmpty);
      expect(files[0].modifiedDate >= files[1].modifiedDate, isTrue);
    });
  });
}
```

### Python Test Template

```python
import pytest
from aichat.routes import chat_completion, embedding

@pytest.fixture
def sample_request():
  return {
    'model': 'gemma-4-12B-it-Q4_0',
    'messages': [{'role': 'user', 'content': 'Hello'}],
  }

def test_chat_completion_success(sample_request, mock_model):
  """Test successful chat completion."""
  response = chat_completion(**sample_request)
  assert response['choices'][0]['message']['content']
  assert response['usage']['total_tokens'] > 0

def test_chat_completion_invalid_model(sample_request):
  """Test error on invalid model."""
  sample_request['model'] = 'invalid-model'
  with pytest.raises(ValueError, match='Model not found'):
    chat_completion(**sample_request)

@pytest.mark.asyncio
async def test_embedding_async(sample_request):
  """Test async embedding generation."""
  result = await embedding(input="Test text")
  assert result['data'][0]['embedding']
```

## Performance Testing

### Flutter Performance

```bash
cd client
flutter run --profile -d macos
# Open DevTools → Performance tab
# Record frame times, memory usage
```

### Python Performance

```bash
cd aiserver
pip install py-spy
py-spy record -o profile.svg -- python main.py
# Then make HTTP requests to profile
# View: python -m http.server (serve profile.svg)
```

## Next Steps

- **[Building & Operations](./building.md)** — Build targets, development workflows
- **[Database Design](../architecture/database.md)** — Schema & migration testing

## Source References

- **Flutter Tests**: `/client/test/`
- **Python Tests**: `/aiserver/tests/`, `/aiserver/src/aichat/tests/`
- **CI Workflows**: `/.github/workflows/`
- **Test Fixtures**: `/client/test/helpers/`, `/aiserver/tests/conftest.py`
