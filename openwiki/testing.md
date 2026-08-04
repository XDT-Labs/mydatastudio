# Testing Guide

My Data Studio has **100+ tests** across Flutter (Dart) and Python:

- **Flutter**: ~80 widget and unit tests
- **Python**: ~50 unit and integration tests

---

## Flutter Testing

### Test Directory Structure

```
client/test/
├── modules/
│   ├── aichat/
│   ├── email/
│   ├── files/
│   ├── photos/           # Recently expanded (photos migration)
│   └── social/
├── repositories/         # Data access tests
├── scanners/             # Background isolate tests
├── services/             # Service/business logic tests
├── helpers/              # Test utilities
├── integration/          # End-to-end workflows
└── ... (app-level tests)
```

### Running Tests

```bash
cd client

# Run all tests
flutter test

# Run specific test file
flutter test test/modules/photos/services/photos_service_test.dart

# Run tests matching pattern
flutter test -k "photos"

# Run with coverage
flutter test --coverage
coverage=$(find . -name "lcov.info" -path "*/coverage/*")

# Run in verbose mode
flutter test -v
```

### Test Types

#### Unit Tests

Pure Dart functions with no UI or database:

```dart
void main() {
  group('ByteFormatter', () {
    test('formats bytes to human-readable string', () {
      expect(ByteFormatter.format(1024), equals('1.0 KB'));
      expect(ByteFormatter.format(1024 * 1024), equals('1.0 MB'));
      expect(ByteFormatter.format(1024 * 1024 * 1024), equals('1.0 GB'));
    });
  });
}
```

#### Widget Tests

UI components with mock dependencies:

```dart
void main() {
  group('PhotoGridTile', () {
    testWidgets('displays file name and date', (WidgetTester tester) async {
      final file = File(
        id: 'test-1',
        name: 'vacation.jpg',
        path: '/photos/vacation.jpg',
        collectionId: 'local',
        createdAt: 1704067200,  // 2024-01-01
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoGridTile(file: file),
          ),
        ),
      );

      expect(find.text('vacation.jpg'), findsOneWidget);
      expect(find.text('Jan 1, 2024'), findsOneWidget);
    });

    testWidgets('shows favorite button on hover', (WidgetTester tester) async {
      final file = File(id: 'test-1', name: 'photo.jpg', collectionId: 'local');

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PhotoGridTile(file: file))),
      );

      // Hover over tile
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.moveTo(tester.getCenter(find.byType(PhotoGridTile)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    });
  });
}
```

#### Integration Tests

Full workflows with real database:

```dart
void main() {
  group('File Browser Integration', () {
    late DatabaseManager databaseManager;

    setUpAll(() async {
      databaseManager = DatabaseManager();
      await databaseManager.initializeDatabase();
    });

    tearDownAll(() async {
      await databaseManager.appDatabase?.close();
    });

    testWidgets('adds file collection and syncs', (WidgetTester tester) async {
      await tester.pumpWidget(const FamilyDamApp());
      await tester.pumpAndSettle(Duration(seconds: 2));

      // Navigate to files page
      expect(find.text('Files'), findsWidgets);
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();

      // Tap "Add Collection"
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // Select local filesystem
      await tester.tap(find.text('Local Filesystem'));
      await tester.pumpAndSettle();

      // Choose directory
      await tester.tap(find.byIcon(Icons.folder_open));
      await tester.pumpAndSettle(Duration(seconds: 5));

      // Verify files loaded
      expect(find.byType(FileTable), findsOneWidget);
    });
  });
}
```

### Widget Test Patterns

#### Testing with Real Database

```dart
void main() {
  group('FileDetailsDrawer with Database', () {
    late DatabaseManager databaseManager;

    setUpAll(() async {
      databaseManager = DatabaseManager();
      await databaseManager.initializeDatabase();
      
      // Insert test data
      await databaseManager.appDatabase?.execute('''
        INSERT INTO files (id, name, path, collection_id, size)
        VALUES (?, ?, ?, ?, ?)
      ''', ['test-file-1', 'photo.jpg', '/photos/photo.jpg', 'local', 2048000]);
    });

    tearDownAll(() async {
      await databaseManager.appDatabase?.close();
    });

    testWidgets('displays file metadata from database', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileDetailsDrawer(fileId: 'test-file-1'),
          ),
        ),
      );

      // Real SQLite I/O doesn't complete under pumpAndSettle's fake clock
      await tester.runAsync(() async {
        await Future.delayed(Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('2.0 MB'), findsOneWidget);  // Formatted size
    });
  });
}
```

**Key Pattern:** Use `tester.runAsync()` for real I/O (database queries, HTTP requests) that don't complete under the test's fake clock.

#### Testing Services (RxService)

```dart
void main() {
  group('PhotosService', () {
    test('emits photos on invoke', () async {
      final service = PhotosService.instance;
      
      final result = await service.invoke(PhotosServiceCommand(
        PhotoFilter(),
      ));

      expect(result, isA<List<File>>());
      expect(result.isNotEmpty, true);

      // Verify service emitted to sink
      service.sink.listen(expectAsync1((photos) {
        expect(photos, isA<List<File>>());
      }));
    });

    test('emits loading state', () async {
      final service = PhotosService.instance;
      final loadingStates = <bool>[];

      service.isLoading.listen((loading) {
        loadingStates.add(loading);
      });

      await service.invoke(PhotosServiceCommand(PhotoFilter()));

      // Should have [true, false]
      expect(loadingStates, containsAll([true, false]));
    });
  });
}
```

#### Testing Scanner Isolates

```dart
void main() {
  group('LocalFileIsolate', () {
    late DatabaseManager databaseManager;

    setUpAll(() async {
      databaseManager = DatabaseManager();
      await databaseManager.initializeDatabase();
    });

    test('scans directory and inserts files', () async {
      final scanner = LocalFileIsolate(
        collectionId: 'test-collection',
        path: '/tmp/test-photos',  // Temp directory
      );

      // Create test files
      final dir = Directory('/tmp/test-photos');
      await dir.create();
      await File('${dir.path}/photo1.jpg').writeAsString('fake image');
      await File('${dir.path}/photo2.png').writeAsString('fake image');

      // Run scanner
      await scanner.start(force: true);

      // Verify files in database
      await Future.delayed(Duration(milliseconds: 500));
      
      final files = await databaseManager.appDatabase?.queryAll('''
        SELECT name FROM files WHERE collection_id = ?
      ''', ['test-collection']);

      expect(files, isNotEmpty);
      expect(files!.map((f) => f['name']), containsAll(['photo1.jpg', 'photo2.png']));

      // Cleanup
      await dir.delete(recursive: true);
    });
  });
}
```

### Test Helpers

**`test/helpers/file_fixture.dart`**

Create test file objects:

```dart
class FileFixture {
  static File createFile({
    String id = 'test-file',
    String name = 'test.jpg',
    String path = '/test.jpg',
    String collectionId = 'local',
    int size = 1024000,
    String mimeType = 'image/jpeg',
  }) {
    return File(
      id: id,
      name: name,
      path: path,
      collectionId: collectionId,
      size: size,
      mimeType: mimeType,
    );
  }

  static List<File> createFileList({int count = 5}) {
    return List.generate(count, (i) => createFile(
      id: 'file-$i',
      name: 'photo-$i.jpg',
    ));
  }
}
```

**`test/helpers/fake_tile_provider.dart`**

Mock tile provider for map tests:

```dart
class FakeTileProvider extends TileProvider {
  @override
  ImageProvider<Object> getImage(Coords<num> coords, TileLayer options) {
    return MemoryImage(Uint8List(256 * 256 * 4));  // Blank tile
  }
}
```

---

## Python Testing

### Test Structure

```
aiserver/
├── tests/               # Integration tests
│   ├── test_routes.py       # All HTTP endpoints
│   ├── test_model_manager.py
│   ├── test_utils.py
│   ├── test_state.py
│   ├── test_auth.py
│   ├── test_pst_parser.py
│   └── conftest.py          # Shared fixtures
│
└── src/aichat/tests/    # Unit tests
    ├── test_pst_parser.py
    └── fixtures/
        ├── aspose_sample.pst
        └── outlook_sample.pst
```

### Running Tests

```bash
cd aiserver

# Run all tests
PYTHONPATH=src pdm run pytest

# Run specific test file
PYTHONPATH=src pdm run pytest tests/test_routes.py

# Run tests matching pattern
PYTHONPATH=src pdm run pytest -k "test_chat"

# Verbose output
PYTHONPATH=src pdm run pytest -v

# Coverage report
PYTHONPATH=src pdm run pytest --cov=src/aichat --cov-report=html
```

### Test Patterns

#### Route Testing

```python
import pytest
from fastapi.testclient import TestClient
from aichat.main import app

@pytest.fixture
def client():
    os.environ['AISERVER_TOKEN'] = 'test-token-123'
    return TestClient(app)

def test_chat_completions(client):
    response = client.post(
        '/v1/chat/completions',
        headers={'Authorization': 'Bearer test-token-123'},
        json={
            'model': 'gemma-4-12b',
            'messages': [{'role': 'user', 'content': 'Hello'}],
            'stream': False,
        },
    )
    
    assert response.status_code == 200
    assert 'choices' in response.json()
    assert response.json()['choices'][0]['message']['role'] == 'assistant'

def test_chat_completions_unauthorized(client):
    response = client.post(
        '/v1/chat/completions',
        headers={'Authorization': 'Bearer wrong-token'},
        json={
            'model': 'gemma-4-12b',
            'messages': [{'role': 'user', 'content': 'Hello'}],
        },
    )
    
    assert response.status_code == 401
```

#### Async Route Testing

```python
@pytest.mark.asyncio
async def test_embedding_generation():
    request = EmbeddingRequest(text='Hello world')
    response = await generate_embedding(request)
    
    assert 'embedding' in response
    assert len(response['embedding']) == 1536  # Embedding dimension
    assert response['model'] == 'Qwen/Qwen3-VL-Embedding-2B'
```

#### Model Manager Testing

```python
def test_load_local_model():
    # Mock model file
    with patch('os.path.exists', return_value=True):
        model = load_local_model('gemma-4-12b')
        
        assert model is not None
        assert isinstance(model, Llama)

def test_embedding_model_caching():
    # First load
    model1 = load_embedding_model()
    # Second load should return cached instance
    model2 = load_embedding_model()
    
    assert model1 is model2
```

#### PST Parser Testing

```python
def test_parse_pst_file(tmp_path):
    # Use fixture PST files in src/aichat/tests/fixtures/
    pst_path = 'src/aichat/tests/fixtures/outlook_sample.pst'
    
    parser = PstParser(pst_path)
    emails = list(parser.iter_emails())
    
    assert len(emails) > 0
    assert all('subject' in email for email in emails)
    assert all('from' in email for email in emails)
```

---

## Debugging Tests

### Flutter

**Run test with output:**

```bash
flutter test -v test/modules/photos/services/photos_service_test.dart
```

**Run single test:**

```bash
flutter test test/modules/photos/widgets/photo_grid_test.dart -k "displays grid layout"
```

**Test with logging:**

```dart
testWidgets('logs debug info', (WidgetTester tester) async {
  debugPrint('Starting test');
  
  await tester.pumpWidget(MyWidget());
  debugPrint('Widget pumped');
  
  expect(find.text('Expected'), findsOneWidget);
  debugPrint('Test passed');
});
```

### Python

**Run with output:**

```bash
PYTHONPATH=src pdm run pytest -s tests/test_routes.py
```

**Run single test with debugger:**

```bash
PYTHONPATH=src pdm run pytest --pdb tests/test_routes.py::test_chat_completions
```

**Print debug info:**

```python
def test_example():
    print("Debug value:", some_variable)  # Shows with -s flag
    assert True
```

---

## Test Coverage

### Flutter Coverage

```bash
cd client
flutter test --coverage
# Generates coverage/lcov.info

# View coverage report (requires lcov)
genhtml coverage/lcov.info -o coverage/html
open coverage/html/index.html
```

### Python Coverage

```bash
cd aiserver
PYTHONPATH=src pdm run pytest --cov=src/aichat --cov-report=html
open htmlcov/index.html
```

---

## CI/CD Testing

Tests run in GitHub Actions on each push:

```yaml
# .github/workflows/build_and_release.yml
- name: Run Flutter Tests
  run: |
    cd client
    flutter test

- name: Run Python Tests
  run: |
    cd aiserver
    PYTHONPATH=src pdm run pytest
```

---

## Known Issues

### Tags and Landmarks Widget Test Hang

`client/test/modules/files/widgets/file_details/tags_and_landmarks_section_test.dart` has a known issue where a test combining real database I/O with `tester.runAsync()` and repeated `TextField` interaction can hang for 2-5+ minutes (see `TODO.md` for investigation notes).

**Workaround:** The test currently runs in load-only mode without add/delete interactions. Feature is verified through:
- `database_repository_test.dart` — Tag CRUD operations
- `file_browser_integration_test.dart` — Real app with widget in tree

---

## Test Checklist for New Features

When adding a new feature:

1. **Unit tests** — Pure logic (formatters, validators, utilities)
2. **Widget tests** — UI components and interactions
3. **Service tests** — RxService command/result flow
4. **Integration test** (if needed) — End-to-end workflow
5. **Coverage** — Aim for >80% line coverage
6. **Async tests** — Use `tester.runAsync()` for real I/O

---

## Next Steps

- See [Flutter Client](./flutter-client.md) for service and repository patterns
- See [Python Service](./python-service.md) for API endpoint details
- See [Build & Deploy](./build-deploy.md) for CI/CD setup
