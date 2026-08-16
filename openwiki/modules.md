# Feature Modules

My Data Studio is organized into modular features under `client/lib/modules/`. Each module follows a consistent pattern: pages, widgets, services, and scanners.

---

## Module Structure

All modules follow this pattern:

```
modules/<feature>/
  pages/           # Screens and page-level components
  widgets/         # Reusable UI components for this module
  services/        # Business logic (RxService subclasses, repositories)
    scanners/      # Background isolate implementations (if any)
  models/          # Module-specific models (if any)
```

---

## Files Module

**Browse and sync local filesystem and Google Drive; extract EXIF, generate thumbnails, semantic search.**

### Key Components

| Component | Purpose |
|-----------|---------|
| `RxFilesPage` | Main file browser with cache-then-scan pattern |
| `FileRepository` | Queries: getFiles, getFolder, updateFile, deleteFile |
| `GetFilesAndFoldersService` | Service: invoke → query cached results + start scanner |
| `LocalFileIsolate` | Scanner: walk local directory, extract EXIF, send to main |
| `CloudFileIsolate` | Scanner: list Google Drive via OAuth, send to main |
| `EmbeddingIsolate` | Generate vector embeddings for image files |

### Pages

**`rx_files_page.dart`**

Main file browser page with:
- Cache-then-scan pattern (immediate render + background sync)
- Left drawer: collections, sources, filters
- Right drawer: selected file metadata
- Toolbar: search, sort, view mode
- Table/grid view of files in folder

**State Management:**

```dart
class RxFilesPage extends StatefulWidget {
  static PublishSubject<String> selectedCollection = PublishSubject();
  static BehaviorSubject<String> sortColumn = BehaviorSubject.seeded("name");
  static BehaviorSubject<bool> sortDirection = BehaviorSubject.seeded(true);
}
```

### Scanners

**`local_file_isolate.dart`**

Runs in isolate, scans local filesystem:

```dart
class LocalFileIsolate extends CollectionScanner {
  Future<void> _scanDirectory(SendPort mainPort) async {
    final directory = Directory(path);
    
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        final metadata = await _extractMetadata(entity);
        await writeViaMain({
          'action': 'insertFile',
          'data': metadata.toMap(),
        });
      }
    }
  }

  static Future<Map<String, dynamic>> _extractMetadata(File file) async {
    // Extract EXIF using native_exif plugin
    final exif = await _extractExif(file.path);
    
    // Generate thumbnail
    final thumbnail = await _generateThumbnail(file.path);
    
    return {
      'id': uuid.v4(),
      'name': file.path.split('/').last,
      'path': file.path,
      'size': await file.length(),
      'mime_type': _detectMimeType(file.path),
      'created_at': (await file.stat()).accessed.millisecondsSinceEpoch ~/ 1000,
      'exif_data': exif,
      'thumbnail': thumbnail,
    };
  }
}
```

**`google_file_scanner.dart`**

Scans Google Drive via OAuth:

```dart
class CloudFileIsolate extends CollectionScanner {
  Future<void> _scanGoogleDrive(SendPort mainPort) async {
    final client = httpClient;  // Initialized with OAuth token
    final drive = DriveApi(client);
    
    var pageToken = '';
    while (true) {
      final files = await drive.files.list(
        pageSize: 100,
        pageToken: pageToken,
      );
      
      for (final file in files.files ?? []) {
        await writeViaMain({
          'action': 'insertFile',
          'data': {
            'id': uuid.v4(),
            'name': file.name,
            'path': 'google-drive://${file.id}',
            'size': int.parse(file.size ?? '0'),
            'mime_type': file.mimeType,
            'created_at': file.createdTime?.millisecondsSinceEpoch,
          },
        });
      }
      
      pageToken = files.nextPageToken;
      if (pageToken == null) break;
    }
  }
}
```

### Key Services

**`FileRepository`**

Queries files, folders, metadata:

```dart
class FileRepository {
  Future<List<File>> getFiles(String collectionId) async => /* ... */;
  Future<List<Folder>> getFolderContents(String folderId) async => /* ... */;
  Future<File?> getFile(String fileId) async => /* ... */;
  Future<void> insertFile(File file) async => /* ... */;
  Future<void> deleteFile(String fileId) async => /* ... */;
  Future<List<File>> searchByVector(List<double> embedding, int limit) async => /* ... */;
}
```

**`GetFilesAndFoldersService extends RxService<GetFilesCommand, GetFilesResult>`**

Cache-then-scan pattern:

```dart
@override
Future<GetFilesResult> invoke(GetFilesCommand command) async {
  isLoading.add(true);
  try {
    // 1. Query cached results immediately
    final cached = await _fileRepo.getFiles(command.collectionId);
    final cachedFolders = await _fileRepo.getFolders(command.collectionId);
    
    sink.add(GetFilesResult(files: cached, folders: cachedFolders));
    
    // 2. Start background scanner (fire-and-forget)
    final scanner = ScannerManager.instance.scannerFor(command.collectionId);
    await scanner?.start(force: true);
    
    return GetFilesResult(files: cached, folders: cachedFolders);
  } finally {
    isLoading.add(false);
  }
}
```

---

## Search Module

**Unified cross-source search combining deterministic query parsing, BM25 full-text retrieval, vector similarity, and location-based ranking.**

The Search module orchestrates queries across files, emails, photos, and documents through a sophisticated pipeline:

1. **Query Parsing** (deterministic) → extract hard filters (`from:`, `tag:`, `near:`, etc.) and free-text remainder
2. **Hard Filter Application** → SQL WHERE clauses define the candidate set (filters are constraints, not scores)
3. **Multi-Retriever Fusion** → BM25 (lexical) + Vector (semantic) + Geo (location) → Reciprocal-Rank Fusion
4. **Ranking** → Recency decay + tier boost + relevance score
5. **Pagination** → Render results with optional result-set summarization for AI chat

### Key Components

| Component | Purpose |
|-----------|---------|
| `SearchPage` | Main search UI, global app-bar integration |
| `SearchService` | Main orchestrator, coordinates parsing + retrieval + ranking |
| `QueryParser` | Regex-based deterministic filter extraction (no LLM) |
| `PersonResolver` | Name → email address resolution via contacts index |
| `QueryPlanner` | Optional AI intent detection for modality (off critical path) |
| `BM25Retriever` | FTS5 lexical search |
| `VectorRetriever` | Brute-force cosine similarity over embeddings |
| `HybridRanker` | Reciprocal-rank fusion (RRF) score combination |
| `ResultRanking` | Apply recency decay + tier boost + pagination |
| `ResultSetSummarizer` | Map-reduce over result set, generate coverage claims for aichat |

### Query Parsing

Supports deterministic filters (no inference):

```
from:bob@example.com  →  emails."from" = ?
to:alice@example.com  →  emails."to" LIKE ?
subject:invoice       →  FTS5 column filter
tag:beach            →  file_tags join
near:banff           →  gazetteer + haversine
after:2026-01-01     →  date >= ?
type:image|pdf|email →  content type predicate
```

Person names resolve via database lookup of email contacts, not embeddings (embeddings encode meaning, not identity).

### Ranking & Fusion

- **BM25** for lexical matching (email subject/body, file descriptions)
- **Vector similarity** (image embeddings, description embeddings, email embeddings)
- **Geo proximity** (haversine distance to geotagged files)
- **RRF** combines all three, scale-free (harmonic mean of reciprocal ranks)
- **Recency** decay `1/(1+ln(1+age_days/365))` floored at 0.75 to keep archives searchable
- **Tier boost** for result type (e.g., email from known contact ranks higher)

**See:** [Search Module Deep Dive](./modules/search.md) for full design, test coverage, and implementation patterns.

---

## Email Module

**Archive and search Gmail, Yahoo, Outlook (IMAP + PST import).**

### Key Components

| Component | Purpose |
|-----------|---------|
| `EmailPage` | Main email inbox/folder browser |
| `NewEmailPage` | Configure new email source (OAuth or IMAP) |
| `EmailRepository` | Queries: getEmails, getFolder, getAttachment |
| `EmailService` | Service: query emails, apply filters |
| `GmailScannerIsolate` | Scanner: Gmail API |
| `OutlookScannerIsolate` | Scanner: IMAP for live Outlook |
| `OutlookPstScannerIsolate` | Scanner: One-time PST file import |
| `YahooPstScannerIsolate` | Scanner: Yahoo IMAP |
| `EmailEmbeddingIsolate` | Generate embeddings for emails |

### Pages

**`email_page.dart`**

Email inbox with:
- Folder tree (left drawer)
- Email list/table (main)
- Email detail view (right drawer)
- Search and filter

**`new_email_page.dart`**

Setup flow:
1. Choose provider (Gmail, Outlook, Yahoo)
2. OAuth or IMAP auth
3. Select folders to sync
4. Save and start scanner

### Scanners

**`gmail_scanner_isolate.dart`**

Uses Gmail API with OAuth:

```dart
class GmailScannerIsolate extends CollectionScanner {
  Future<void> _scanGmail(SendPort mainPort) async {
    final gmail = GmailApi(httpClient);
    
    final messages = await gmail.users.messages.list(
      'me',
      q: 'after:2024/01/01',
    );
    
    for (final msg in messages.messages ?? []) {
      final full = await gmail.users.messages.get('me', msg.id!);
      
      final headers = full.payload?.headers ?? [];
      final subject = headers.firstWhere(
        (h) => h.name == 'Subject',
        orElse: () => Header(value: '(No Subject)'),
      ).value;
      
      await writeViaMain({
        'action': 'insertEmail',
        'data': {
          'id': uuid.v4(),
          'provider': 'gmail',
          'message_id': msg.id,
          'subject': subject,
          'from': _extractEmail(headers, 'From'),
          'to': _extractEmail(headers, 'To'),
          'received_at': int.parse(full.internalDate ?? '0') ~/ 1000,
          'body': _extractBody(full.payload),
        },
      });
    }
  }
}
```

**`outlook_pst_scanner_isolate.dart`**

One-time PST import (user-triggered):

```dart
class OutlookPstScannerIsolate extends CollectionScanner {
  Future<void> _scanPst(SendPort mainPort, String filePath) async {
    // Call aiserver POST /util/import/pst endpoint
    final response = await http.post(
      Uri.parse('${MainApp.llmServiceUrl.value}/util/import/pst'),
      headers: {'Authorization': 'Bearer ${MainApp.llmServiceToken.value}'},
      body: jsonEncode({'file_path': filePath}),
    );
    
    // Stream parse JSONL response
    for (final line in response.body.split('\n')) {
      if (line.isEmpty) continue;
      final emailData = jsonDecode(line);
      
      await writeViaMain({
        'action': 'insertEmail',
        'data': emailData,
      });
    }
  }
}
```

### Key Services

**`EmailRepository`**

```dart
class EmailRepository {
  Future<List<Email>> getEmails(String folderId) async => /* ... */;
  Future<List<EmailFolder>> getFolders() async => /* ... */;
  Future<Email?> getEmail(String emailId) async => /* ... */;
  Future<List<Attachment>> getAttachments(String emailId) async => /* ... */;
  Future<void> insertEmail(Email email) async => /* ... */;
  Future<void> insertFolder(EmailFolder folder) async => /* ... */;
}
```

---

## Photos Module (Flutter Migration)

**Photo gallery with 4 view modes, metadata editing, albums, keyboard shortcuts.**

Recently migrated from React mockup (commit 28041d9) to full Flutter implementation.

### Key Components

| Component | Purpose |
|-----------|---------|
| `PhotosApp` | Main photos page with toolbar, drawer, view switcher |
| `PhotosService extends RxService` | Fetch photos, apply filter, group by date/location |
| `PhotosRepository` | Queries: photos, photosByDate, photosWithLocation, albums, tags |
| `SelectionService` | Multi-select state (batch operations) |
| `ViewStateService` | Current view mode, filter state, sort |
| `BatchActionService` | Bulk delete, favorite, move to album |

### Views (4 Modes)

**Grid View** (`photo_grid.dart`)

Responsive grid with:
- Auto-sizing columns (2–6 based on window width)
- Date-grouped sections with headers
- Hover overlays: select checkbox, favorite, lightbox, location badge
- Empty state messaging

```dart
class PhotoGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      gridDelegate: SliverGridDelegateWithAdaptiveMainAxisExtent(
        mainAxisExtent: 256,
      ),
      delegate: SliverChildListDelegate([
        for (final date in photos.keys)
          DateSectionHeader(date: date),
        for (final photo in photos.values.expand((list) => list))
          PhotoGridTile(photo: photo),
      ]),
    );
  }
}
```

**List View** (`photo_list_view.dart`)

Tabular metadata view:
- Sortable columns (name, size, date, location)
- Hover/selection states
- Formatted file details

**Timeline View** (`photo_timeline_view.dart`)

Month-grouped chronological view:
- Month-grouped grid sections
- Quick-jump sidebar for year/month navigation
- Scroll tracking with animated focus

```dart
class TimelineQuickJump extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final year in years.keys)
          ExpansionTile(
            title: Text(year),
            children: [
              for (final month in years[year]!)
                ListTile(
                  title: Text(month),
                  onTap: () => _scrollTo(year, month),
                ),
            ],
          ),
      ],
    );
  }
}
```

**Map View** (`photo_map_view.dart`)

FlutterMap with:
- CartoDB Dark Matter tiles (free, keyless)
- Marker clustering (zoom-based)
- Chronological route polyline
- Trip playback controller with speed control

```dart
class PhotoMapView extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      options: MapOptions(center: LatLng(40, -95)),
      layers: [
        TileLayer(urlTemplate: 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'),
        MarkerClusterLayer(
          markers: _buildMarkers(photos),
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: _buildChronologicalRoute(photos),
              color: Colors.amber,
              strokeWidth: 2,
            ),
          ],
        ),
      ],
    );
  }
}
```

### Album Management

**Album Modal** (`album_modal.dart`)

Create new album or add to existing:

```dart
class AlbumModal extends StatefulWidget {
  @override
  State<AlbumModal> createState() => _AlbumModalState();
}

class _AlbumModalState extends State<AlbumModal> {
  Future<void> _createAlbum() async {
    final album = Album(
      id: uuid.v4(),
      name: _nameController.text,
      description: _descController.text,
      created_at: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    
    await PhotosRepository().insertAlbum(album);
    
    // Add selected files to album
    for (final fileId in SelectionService.instance.selected) {
      await PhotosRepository().insertAlbumFile(album.id, fileId);
    }
    
    Navigator.pop(context);
  }
}
```

**Album Detail Page** (`album_detail_page.dart`)

View and manage album membership:
- Display cover image
- Grid of photos in album
- Reorder, remove, or add photos
- Edit album name/description

### Keyboard Shortcuts

**`keyboard_shortcut_handler.dart`**

Global keyboard event handling:

| Key | Action |
|-----|--------|
| Space | Open lightbox for selected photo |
| I | Toggle info sidebar |
| Escape | Close lightbox/sidebar |
| F | Toggle favorite |
| Delete | Batch delete selected |
| Ctrl+A | Select all visible |
| ? | Show keyboard shortcuts help modal |

```dart
class KeyboardShortcutHandler extends StatefulWidget {
  @override
  State<KeyboardShortcutHandler> createState() => _KeyboardShortcutHandlerState();
}

class _KeyboardShortcutHandlerState extends State<KeyboardShortcutHandler> {
  @override
  void initState() {
    super.initState();
    RawKeyboard.instance.addListener(_handleKey);
  }

  void _handleKey(RawKeyEvent event) {
    if (event.isKeyPressed(LogicalKeyboardKey.space)) {
      _openLightbox();
    } else if (event.isKeyPressed(LogicalKeyboardKey.keyI)) {
      ViewStateService.instance.toggleInfoSidebar();
    } else if (event.logicalKey == LogicalKeyboardKey.delete) {
      _batchDelete();
    }
  }
}
```

### Key Services

**`PhotosService extends RxService<PhotosServiceCommand, List<File>>`**

```dart
class PhotosService extends RxService<PhotosServiceCommand, List<File>> {
  @override
  Future<List<File>> invoke(PhotosServiceCommand command) async {
    final repo = PhotosRepository();
    final filter = command.filter;
    
    // Apply filters
    var query = 'SELECT * FROM files WHERE mime_type LIKE "image/%"';
    var params = [];
    
    if (filter.searchQuery.isNotEmpty) {
      query += ' AND name LIKE ?';
      params.add('%${filter.searchQuery}%');
    }
    
    if (filter.sourceType != null) {
      query += ' AND source_type = ?';
      params.add(filter.sourceType);
    }
    
    if (filter.tag != null) {
      query += ' AND id IN (SELECT file_id FROM file_tags WHERE tag = ?)';
      params.add(filter.tag);
    }
    
    final files = await repo.photos(filter: filter);
    sink.add(files);
    
    return files;
  }
}
```

**`PhotosRepository`**

```dart
class PhotosRepository {
  Future<List<File>> photos({PhotoFilter? filter}) async => /* ... */;
  Future<Map<String, List<File>>> photosByDate({PhotoFilter? filter}) async => /* ... */;
  Future<Map<String, List<File>>> photosByMonth({PhotoFilter? filter}) async => /* ... */;
  Future<List<File>> photosWithLocation({PhotoFilter? filter}) async => /* ... */;
  Future<Map<String, int>> allTags() async => /* ... */;
  Future<Map<String, int>> allLocations() async => /* ... */;
  Future<void> insertAlbum(Album album) async => /* ... */;
  Future<void> insertAlbumFile(String albumId, String fileId) async => /* ... */;
  Future<void> favorite(String fileId) async => /* ... */;
  Future<void> unfavorite(String fileId) async => /* ... */;
}
```

**`SelectionService`**

Track multi-select state:

```dart
class SelectionService {
  static final SelectionService _instance = SelectionService._();
  static SelectionService get instance => _instance;

  final BehaviorSubject<Set<String>> selected = BehaviorSubject.seeded({});

  void toggle(String fileId) {
    final current = selected.value;
    if (current.contains(fileId)) {
      current.remove(fileId);
    } else {
      current.add(fileId);
    }
    selected.add({...current});
  }

  void selectAll(List<String> fileIds) {
    selected.add(fileIds.toSet());
  }

  void clear() {
    selected.add({});
  }
}
```

---

## AI Chat Module

**Semantic search and chat across all collected data using local/cloud LLMs.**

### Key Components

| Component | Purpose |
|-----------|---------|
| `AichatPage` | Chat interface with message history |
| `AichatModelsSettingsPage` | Model selection and configuration |
| `LocalLlmContentGenerator` | Implements `genui` `ContentGenerator` interface |
| `AichatRepository` | Queries: conversations, messages, models |

### Pages

**`aichat_page.dart`**

Chat interface:
- Message list (scrollable history)
- Text input with file attachments
- Model selector dropdown
- Streaming response rendering

**`aichat_models_settings_page.dart`**

Configure models:
- Select local vs cloud model
- Download GGUF models (with progress)
- Configure cloud API keys (Gemini, Claude, OpenAI)
- Manage model cache

### LocalLlmContentGenerator

Wraps chat requests behind the `genui` `ContentGenerator` interface:

```dart
class LocalLlmContentGenerator extends ContentGenerator {
  @override
  Stream<String> generate(String prompt, {String? systemPrompt}) {
    return _streamChat(prompt, systemPrompt);
  }

  Future<Stream<String>> _streamChat(String prompt, String? system) async {
    final url = MainApp.llmServiceUrl.value;
    final token = MainApp.llmServiceToken.value;
    
    final response = await http.post(
      Uri.parse('$url/v1/chat/completions'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'gemma-4-12b',
        'messages': [
          if (system != null) {'role': 'system', 'content': system},
          {'role': 'user', 'content': prompt},
        ],
        'stream': true,
      }),
    );
    
    if (response.statusCode != 200) {
      throw Exception('Chat API error: ${response.statusCode}');
    }
    
    // Parse streaming response
    yield* response.stream
      .transform(utf8.decoder)
      .transform(LineSplitter())
      .where((line) => line.isNotEmpty)
      .map((line) {
        final json = jsonDecode(line.replaceFirst('data: ', ''));
        return json['choices'][0]['delta']['content'] ?? '';
      });
  }
}
```

---

## Social Module (Placeholder)

**No scanner or data ingestion yet.**

Placeholder UI only for:
- Facebook
- Twitter/X
- Instagram

---

## Module Extension Points

### Adding a New Scanner

1. Create `modules/<feature>/services/scanners/<source>_isolate.dart`
2. Extend `CollectionScanner` with `isScanning` BehaviorSubject
3. Implement `start()` and `stop()` lifecycle methods
4. Use `writeViaMain()` to relay writes to main isolate
5. Register in `ScannerManager.register()` during startup
6. Add tests in `test/scanners/`

### Adding a New Service

1. Create `modules/<feature>/services/<feature>_service.dart`
2. Extend `RxService<Command, Result>`
3. Implement `invoke(Command)` with business logic
4. Make singleton with static `instance` getter
5. Use `sink.add()` and `isLoading.add()` to emit state
6. Add tests in `test/modules/<feature>/services/`

### Adding Module Pages

1. Create `modules/<feature>/pages/<page>_page.dart`
2. Add route to `app_router.dart`
3. Use RxService singletons for data
4. Subscribe to services/subjects in `initState`
5. Always unsubscribe in `dispose`
6. Add tests in `test/modules/<feature>/pages/`

---

## Next Steps

- See [Flutter Client](./flutter-client.md) for repository and service patterns
- See [Data Models](./data-models.md) for database schema
- See [Architecture](./architecture.md) for isolate communication and state management
