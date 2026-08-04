# Flutter Client Architecture

The Flutter client is built with Dart 3.12 targeting macOS (Windows/Linux support planned). It handles the UI, local database, background scanning, and communication with the bundled Python aiserver.

---

## Directory Structure

```
client/lib/
├── main.dart                    # App entry point, MainApp global state
├── family_dam_app.dart          # Root widget configuration
├── app_router.dart              # go_router routes for all modules
├── app_logger.dart              # Logging infrastructure
├── app_constants.dart           # App-wide constants
├── database_manager.dart        # AppDatabase schema + startBackgroundServices()
├── python_manager.dart          # Spawns/monitors aiserver subprocess
│
├── models/
│   └── tables/                  # Database models (hand-written)
│       ├── app_user.dart
│       ├── file.dart
│       ├── email.dart
│       ├── album.dart
│       ├── file_embedding.dart
│       └── ... (10+ more)
│
├── modules/                     # Feature modules
│   ├── aichat/                  # AI chat & semantic search
│   │   ├── pages/
│   │   ├── widgets/
│   │   └── services/
│   ├── files/                   # Local & cloud file browsing
│   │   ├── pages/
│   │   ├── widgets/
│   │   ├── services/
│   │   └── services/scanners/   # LocalFileIsolate, CloudFileIsolate
│   ├── email/                   # Email archive & search
│   │   ├── pages/
│   │   ├── widgets/
│   │   ├── services/
│   │   └── services/scanners/   # Gmail, Outlook, Yahoo scanners
│   ├── photos/                  # Photo gallery (Flutter migration)
│   │   ├── pages/
│   │   ├── widgets/
│   │   ├── services/
│   │   ├── models/              # PhotoFilter, Album metadata
│   │   └── utils/               # Formatters, helpers
│   └── social/                  # Placeholder UI only
│
├── repositories/                # Data access layer (resqlite)
│   ├── database_repository.dart       # Generic DB query helper
│   ├── collection_repository.dart     # Collection/source management
│   ├── user_repository.dart
│   ├── aichat_repository.dart
│   └── ... (5+ more)
│
├── services/                    # Cross-module services
│   ├── rx_service.dart          # Base class RxService<C,R>
│   ├── scan_write_relay.dart    # Isolate write coordination
│   ├── embedding_message_handler.dart
│   ├── sequential_write_queue.dart
│   ├── model_download_manager.dart
│   ├── update_checker.dart
│   └── ... (6+ more)
│
├── scanners/                    # Scan orchestration
│   ├── scanner_manager.dart     # Lifecycle + registration
│   ├── scan_isolate_support.dart # Write relay utilities
│   └── collection_scanner.dart  # Base scanner interface
│
├── file_sources/                # Source integrations
│   ├── file_source_provider.dart
│   ├── file_source_registry.dart
│   ├── local/
│   │   └── local_file_provider.dart
│   └── google_drive/
│       ├── google_auth_service.dart
│       └── google_drive_provider.dart
│
├── oauth/                       # OAuth2 flows
│   ├── desktop_oauth_manager.dart
│   ├── login_providers.dart
│   └── json_accepting_http_client.dart
│
├── pages/                       # Top-level pages
│   ├── home.dart
│   ├── login.dart
│   ├── setup.dart
│   └── splash.dart
│
├── widgets/                     # Reusable UI components
│   ├── adaptive_app_bar.dart
│   ├── collapsing_drawer.dart
│   ├── auth_dialog_manager.dart
│   ├── router/
│   │   ├── navigation_wrapper.dart
│   │   └── status_message.dart
│   └── ... (20+ more)
│
├── helpers/                     # Utility functions
│   ├── encryption_form_validator.dart
│   ├── file_path_resolver.dart
│   └── sql_chunks.dart
│
└── l10n/                        # Localization/i18n
    ├── app_en.arb
    └── app_*.arb
```

---

## Core Components

### MainApp: Global State

`main.dart` defines the root widget and global `BehaviorSubject`s accessible anywhere:

```dart
class MainApp {
  // Directory paths
  static final BehaviorSubject<Directory?> supportDirectory = BehaviorSubject();
  static final BehaviorSubject<String?> appDataDirectory = BehaviorSubject();

  // LLM service URL and auth token
  static final BehaviorSubject<String?> llmServiceUrl = BehaviorSubject();
  static final BehaviorSubject<String?> llmServiceToken = BehaviorSubject();

  // Usage from anywhere
  static void initPaths(Directory support, String appData) {
    supportDirectory.add(support);
    appDataDirectory.add(appData);
  }
}
```

### AppDatabase & Schema

`database_manager.dart` contains:

1. **Schema DDL** — All `CREATE TABLE` statements
2. **AppDatabase** — resqlite wrapper with connection management
3. **Startup** — Migration logic and background service initialization

**Schema Coverage:**
- `app_user` — User account and authentication
- `files` — File metadata, paths, EXIF, thumbnails
- `folders` — Directory structure
- `file_embeddings` — Vector storage (resqlite_vector)
- `emails` — Email messages, headers, attachments
- `email_embeddings` — Email vectors
- `albums` — Photo albums and organization
- `album_files` — Album membership
- `file_tags` — Flexible tagging system
- `providers` — OAuth credentials (encrypted)
- `aichat_*` — Chat conversations and models

**Key Methods:**

```dart
class AppDatabase {
  // Execute raw SQL
  Future<void> execute(String sql, [List<dynamic>? args]);

  // Query single row
  Future<Map<String, dynamic>?> queryOne(String sql, [List<dynamic>? args]);

  // Query multiple rows
  Future<List<Map<String, dynamic>>> queryAll(String sql, [List<dynamic>? args]);

  // Vector search (resqlite_vector)
  Future<List<Map<String, dynamic>>> vectorSearch(
    String tableName,
    String vectorColumn,
    List<double> queryVector,
    int limit,
  );

  // Transaction support
  Future<T> transaction<T>(Future<T> Function() fn);
}
```

### PythonManager

`python_manager.dart` manages the aiserver subprocess:

```dart
class PythonManager {
  // Spawn subprocess on app launch
  Future<void> startAiServerService() async {
    // 1. Unzip bundled aiserver-<platform>.zip if needed
    // 2. Generate bearer token
    // 3. Spawn process with env vars: APP_SUPPORT_DIR, AICHAT_MODELS_DIR, AISERVER_TOKEN
    // 4. Scan stdout for http://127.0.0.1:<port>
    // 5. Broadcast URL via MainApp.llmServiceUrl
  }

  // Stop subprocess on app close
  Future<void> stopAiServerService() async {
    // SIGTERM → wait 5s → SIGKILL
  }
}
```

---

## Repositories: Data Access Layer

Repositories provide type-safe queries over the raw database.

### Base Repository Pattern

```dart
class MyRepository {
  final AppDatabase _database;
  MyRepository(this._database);

  Future<List<File>> getFilesByCollection(String collectionId) async {
    final rows = await _database.queryAll('''
      SELECT * FROM files
      WHERE collection_id = ? AND deleted_at IS NULL
      ORDER BY name
    ''', [collectionId]);
    
    return rows.map((row) => File.fromMap(row)).toList();
  }

  Future<void> insertFile(File file) async {
    await _database.execute('''
      INSERT INTO files (id, name, path, ...)
      VALUES (?, ?, ?, ...)
    ''', [file.id, file.name, file.path, ...]);
  }
}
```

### Key Repositories

| Repository | Purpose |
|------------|---------|
| `DatabaseRepository` | Core queries (users, files, emails, embeddings) |
| `CollectionRepository` | Collection/source CRUD |
| `UserRepository` | User account & preferences |
| `AichatRepository` | Chat conversations and models |
| `EmailRepository` | Email queries and folder management |

Repositories are **singletons** and accessed via `Repository.instance`.

---

## Services: Business Logic

Services extend `RxService<C, R>` and orchestrate repositories, scanners, and APIs.

### Example: PhotosService

```dart
class PhotosService extends RxService<PhotosServiceCommand, List<File>> {
  static final PhotosService _instance = PhotosService._();
  static PhotosService get instance => _instance;

  @override
  Future<List<File>> invoke(PhotosServiceCommand command) async {
    isLoading.add(true);
    try {
      final photos = await PhotosRepository().photos(filter: command.filter);
      sink.add(photos);
      return photos;
    } finally {
      isLoading.add(false);
    }
  }
}

// Usage in UI
@override
void initState() {
  super.initState();
  _sub = PhotosService.instance.sink.listen((photos) {
    setState(() => _photos = photos);
  });

  WidgetsBinding.instance.addPostFrameCallback((_) {
    PhotosService.instance.invoke(PhotosServiceCommand(filter));
  });
}
```

### Common Services

| Service | Command | Result |
|---------|---------|--------|
| `PhotosService` | `PhotosServiceCommand(filter)` | `List<File>` |
| `EmailService` | `GetEmailsCommand(folder, query)` | `List<Email>` |
| `GetCollectionsService` | `GetCollectionsServiceCommand()` | `List<Collection>` |
| `LocalLlmContentGenerator` | Chat/embedding requests | Streaming/buffered responses |

---

## Scanners: Background Data Collection

Scanners run in **Dart Isolates** and discover/sync data from sources (local FS, Google Drive, Gmail, Outlook, Yahoo).

### Scanner Lifecycle

```
1. Registration (ScannerManager.register() during startup)
   → Scanner exists but is not yet running

2. Start (scanner.start() when user navigates or manually triggers sync)
   → Isolate spawned
   → Discovery phase runs
   → Emit items to database via write relay
   → Emit scanner.isScanning = false when done

3. Background resumption (automatic if configured)
   → Periodic or event-driven sync
```

### Scanner Interface

```dart
abstract class CollectionScanner {
  final String collectionId;
  final BehaviorSubject<bool> isScanning = BehaviorSubject.seeded(false);

  Future<void> start({bool force = false});
  Future<void> stop();
  Future<void> dispose();
}
```

### Example: LocalFileIsolate

`modules/files/services/scanners/local_file_isolate.dart`

```dart
class LocalFileIsolate extends CollectionScanner {
  @override
  Future<void> start({bool force = false}) async {
    if (isScanning.value && !force) return;
    
    isScanning.add(true);
    try {
      final isolate = await Isolate.spawn(_scanDirectory, _isolateData);
      // Receive results from isolate, relay writes to main
    } finally {
      isScanning.add(false);
    }
  }

  static Future<void> _scanDirectory(SendPort port) async {
    final db = AppDatabase();
    final directory = Directory(path);
    
    // Walk directory tree
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        // Extract metadata (EXIF, thumbnail)
        final fileRecord = await _extractMetadata(entity);
        
        // Send write request to main isolate
        await writeViaMain({
          'action': 'insertFile',
          'data': fileRecord.toMap(),
        });
      }
    }
  }
}
```

### Email Scanners

Email scanners (Gmail, Outlook, Yahoo) follow a similar pattern but:

1. Authenticate via OAuth
2. Connect to email provider API (Gmail, IMAP, Outlook REST)
3. List messages and download attachments
4. Extract inline attachments (CID refs)
5. Relay writes via `SequentialWriteQueue` to preserve order

---

## Embedding Isolates

Similar to scanners, but generate vector embeddings for discovered items.

### EmbeddingIsolate (Files)

`modules/files/services/embedding_isolate.dart`

```dart
class EmbeddingIsolate {
  static Future<void> startBackgroundEmbedding() async {
    await Isolate.spawn(_embeddingLoop, _isolateData);
  }

  static Future<void> _embeddingLoop(SendPort port) async {
    final db = AppDatabase();
    
    while (true) {
      // Wait for signal to pause (when any scanner is active)
      // Query all files without embeddings
      final files = await db.queryAll('''
        SELECT f.* FROM files f
        LEFT JOIN file_embeddings fe ON f.id = fe.file_id
        WHERE fe.id IS NULL AND f.mime_type LIKE 'image/%'
        LIMIT 10
      ''');

      for (final file in files) {
        // Call aiserver /util/embedding endpoint
        final embedding = await _fetchEmbedding(file);
        
        // Relay write to main isolate
        await writeViaMain({
          'action': 'insertEmbedding',
          'data': {
            'file_id': file['id'],
            'vector': embedding,
          },
        });
      }

      await Future.delayed(Duration(seconds: 5));  // Poll every 5s
    }
  }
}
```

### EmailEmbeddingIsolate

Similar, but processes emails and pauses when email scanner is active.

---

## Routing: go_router

`app_router.dart` defines all routes:

```dart
final GoRouter appRouter = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const HomePage(),
      redirect: (context, state) {
        if (!isLoggedIn) return '/login';
        return null;
      },
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: '/files',
      builder: (context, state) => const RxFilesPage(),
      routes: [
        GoRoute(
          path: 'collections/:collectionId',
          builder: (context, state) => FileCollectionPage(
            collectionId: state.pathParameters['collectionId']!,
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/photos',
      builder: (context, state) => const PhotosApp(),
      routes: [
        GoRoute(
          path: 'albums/:albumId',
          builder: (context, state) => AlbumDetailPage(
            albumId: state.pathParameters['albumId']!,
          ),
        ),
      ],
    ),
    // ... email, aichat, social
  ],
);
```

---

## Module Structure

Each module (files, email, photos, aichat) follows a consistent pattern.

### Files Module

**Pages:**
- `rx_files_page.dart` — Main file browser (with cache-then-scan pattern)
- `new_file_collection_page.dart` — Add collection flow

**Scanners:**
- `local_file_isolate.dart` — Scan local filesystem
- `google_file_scanner.dart` — Scan Google Drive via OAuth

**Services:**
- `file_repository.dart` — File queries
- `get_files_and_folders_service.dart` — Cache-then-scan service
- `embedding_isolate.dart` — Vector generation for files

**Widgets:**
- `file_drawer.dart` — Left sidebar with collections, filters
- `file_table.dart` — Main file list/grid
- `file_details_drawer.dart` — Right-side metadata panel

### Email Module

**Pages:**
- `email_page.dart` — Email inbox/folder browser
- `new_email_page.dart` — Configure new email source

**Scanners:**
- `gmail_scanner_isolate.dart` — Gmail API
- `outlook_scanner_isolate.dart` — IMAP for live Outlook
- `outlook_pst_scanner_isolate.dart` — One-time PST import
- `yahoo_scanner_isolate.dart` — Yahoo IMAP

**Services:**
- `email_repository.dart` — Email queries
- `email_embedding_isolate.dart` — Vector generation for emails

### Photos Module (Flutter Migration)

Recently migrated from React mockup to full Flutter implementation (commit 28041d9).

**Key Services:**
- `PhotosService` — Fetch photos, apply filters
- `SelectionService` — Multi-select state
- `ViewStateService` — Current view mode, filter state
- `BatchActionService` — Bulk delete, favorite, move to album

**Views (4 modes):**
- **Grid View** — Responsive grid with date sections, hover overlays
- **List View** — Tabular metadata with sortable columns
- **Timeline View** — Month-grouped chronological view with quick-jump sidebar
- **Map View** — FlutterMap with CartoDB tiles, marker clustering, trip playback

**Widgets:**
- `photo_grid.dart` — Responsive grid layout
- `fullscreen_viewer.dart` — Lightbox with zoom, slideshow, EXIF overlay
- `info_sidebar.dart` — Animated metadata panel, inline title editing, tag management
- `photo_drawer.dart` — 5-section left nav (Library, Sources, Albums, Tags, Locations)
- `photos_toolbar.dart` — Search, filter dropdown, view mode switcher, batch actions
- `album_modal.dart` — Create album or add to existing
- `keyboard_shortcut_handler.dart` — Space (lightbox), I (info), F (favorite), Delete, etc.

### AI Chat Module

**Pages:**
- `aichat_page.dart` — Chat interface with message history
- `aichat_models_settings_page.dart` — Model selection and configuration

**Services:**
- `local_llm_content_generator.dart` — Implements `genui` `ContentGenerator`, calls aiserver HTTP endpoints

---

## Theme & Styling

### Material 3 Dark Theme

Defined in `color_schemes.g.dart`, based on **Obsidian** dark palette:

- **Surface** — `#141317` (very dark)
- **Primary** — `#e8ddff` (lavender)
- **Secondary** — `#ccc2dc` (muted lavender)
- **Tertiary** — `#ffdf97` (warm gold)
- **Error** — `#ffb4ab` (coral)

**Fonts:**
- Primary — Montserrat (headings)
- Secondary — Public Sans (body)
- Mono — Inter (code/technical)

### Custom Widgets

- `AdaptiveAppBar` — Responsive macOS/Linux-styled header
- `CollapsingDrawer` — Collapsible left/right sidebars
- `AccessibleTap` — Keyboard-accessible tap target
- `ProgressiveImage` — Image with blur-up effect and caching

---

## Authentication & Security

### OAuth2 Flows

`oauth/` handles OAuth for Google Drive, Gmail, Yahoo:

```dart
class DesktopOAuthManager {
  // Initiates OAuth flow, opens system browser
  Future<TokenResponse> authorize(AuthProvider provider) async {
    // 1. Generate state + PKCE challenge
    // 2. Open default browser to provider's authorization URL
    // 3. Listen on localhost:8888 for callback with code
    // 4. Exchange code for tokens
    // 5. Store refresh token in secure vault
  }

  // Refresh token when expired
  Future<TokenResponse> refresh(String refreshToken) async {
    // Exchange refresh token for new access token
  }
}
```

### Credential Storage

Credentials are **encrypted** and stored in the secure vault:

```dart
class SecureVault {
  Future<void> set(String key, String value) async {
    final encrypted = _encryptAES(value);
    await _prefs.setString(key, encrypted);
  }

  Future<String?> get(String key) async {
    final encrypted = _prefs.getString(key);
    return encrypted != null ? _decryptAES(encrypted) : null;
  }
}
```

---

## Testing

Flutter tests are in `client/test/` with 100+ test files covering:

- **Unit Tests** — Models, utilities, repositories
- **Widget Tests** — UI components, pages, interactions
- **Integration Tests** — Full workflows (e.g., `file_browser_integration_test.dart`)

### Running Tests

```bash
cd client
flutter test                              # Run all tests
flutter test test/modules/photos/         # Run module tests
flutter test -k "photos"                  # Run tests matching pattern
flutter test --coverage                   # Generate coverage report
```

### Test Patterns

**Widget Test with Real Database:**

```dart
void main() {
  group('FileDetailsDrawer', () {
    late DatabaseManager databaseManager;

    setUpAll(() async {
      // Real SQLite database for this test
      databaseManager = DatabaseManager();
      await databaseManager.initializeDatabase();
    });

    tearDownAll(() async {
      await databaseManager.appDatabase?.close();
    });

    testWidgets('displays file metadata', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: FileDetailsDrawer(fileId: 'test-file')),
      );

      // Use tester.runAsync() for real I/O (SQLite queries)
      await tester.runAsync(() async {
        await Future.delayed(Duration(milliseconds: 100));
      });

      expect(find.text('test-file'), findsOneWidget);
    });
  });
}
```

---

## Performance Considerations

### Database Indexing

Key indices for common queries (in schema DDL):

```sql
CREATE INDEX idx_files_collection_id ON files(collection_id);
CREATE INDEX idx_files_folder_id ON files(folder_id);
CREATE INDEX idx_emails_folder_id ON emails(folder_id);
CREATE INDEX idx_file_embeddings_file_id ON file_embeddings(file_id);
```

### Isolate Staggering

Background isolates start ~500ms apart to avoid thundering-herd contention:

```dart
await Future.delayed(Duration(milliseconds: 500));  // In startBackgroundServices()
```

### Vector Search Optimization

resqlite_vector uses approximate nearest neighbor (ANN) indices for fast semantic search:

```dart
final results = await db.vectorSearch(
  'file_embeddings',
  'vector',
  queryVector,
  limit: 10,  // Return top 10 similar files
);
```

---

## Common Extensions & Patterns

### Adding a New Module

1. Create `modules/<feature>/` with `pages/`, `widgets/`, `services/` subdirectories
2. Add `<feature>Service extends RxService<C,R>` (singleton)
3. Add `<feature>Repository` for database queries
4. Add route to `app_router.dart`
5. Add test files in `test/modules/<feature>/`

### Adding a New Scanner

1. Create `modules/<feature>/services/scanners/<source>_isolate.dart`
2. Extend `CollectionScanner` with `isScanning` BehaviorSubject
3. Implement `start()` and `stop()` methods
4. Use `writeViaMain()` to relay database writes
5. Register in `ScannerManager.register()` during startup
6. Add tests in `test/scanners/`

### Querying the Database

```dart
// Get a single result
final user = await db.queryOne(
  'SELECT * FROM app_user WHERE id = ?',
  [userId],
);

// Get multiple results
final files = await db.queryAll(
  'SELECT * FROM files WHERE folder_id = ? ORDER BY name',
  [folderId],
);

// Execute a write
await db.execute(
  'INSERT INTO files (id, name, path) VALUES (?, ?, ?)',
  [id, name, path],
);

// Vector search
final similar = await db.vectorSearch(
  'file_embeddings',
  'vector',
  queryEmbedding,
  limit: 5,
);
```

---

## Next Steps

- See [Python Service](./python-service.md) for aiserver endpoints and model management
- See [Data Models](./data-models.md) for database schema details
- See [Modules](./modules.md) for module-specific architecture
- See [Testing](./testing.md) for comprehensive test patterns
