# State Management

MyDataStudio uses **RxDart streams** (BehaviorSubject and PublishSubject) for all state management. There is no Provider, Bloc, Riverpod, or other state management library — just reactive Dart.

## Architecture

### Global State (MainApp)

App-wide singletons live in `/client/lib/main.dart`:

```dart
class MainApp {
  // LLM service URL (discovered at startup)
  static final llmServiceUrl = BehaviorSubject<String?>();
  
  // Current authenticated user
  static final currentUser = BehaviorSubject<AppUser?>();
  
  // App file system paths
  static final supportDirectory = BehaviorSubject<Directory?>();
  static final appDataDirectory = BehaviorSubject<Directory?>();
  
  // UI theme
  static final isDarkMode = BehaviorSubject<bool>(true);
}
```

**BehaviorSubject** = remembers the last emitted value. Any new subscriber immediately gets the current value.

### Page-Level State (RxService)

Each page manages its own state via a **RxService** — a base class that wraps queries and exposes observable streams:

```dart
// In repositories/ or services/
class RxFilesPage extends RxService<List<File>, FilesPageState> {
  final FilesPageState _state = FilesPageState();
  
  @override
  Stream<FilesPageState> invoke() async* {
    final files = await _fileRepository.getFiles(
      folderId: _state.currentFolderId,
      sortBy: _state.sortBy,
    );
    _state.files = files;
    yield _state;
  }
  
  // Public API for widgets to call
  Future<void> navigateToFolder(int folderId) async {
    _state.currentFolderId = folderId;
    // Calling invoke() re-queries the database
    await for (final state in invoke()) {
      // Stream new state to subscribers
    }
  }
}

// State object
class FilesPageState {
  List<File> files = [];
  int? currentFolderId;
  SortBy sortBy = SortBy.name;
}
```

Widgets subscribe to the stream and rebuild on changes:

```dart
// In widget
@override
Widget build(BuildContext context) {
  return StreamBuilder<FilesPageState>(
    stream: rxFilesPage.stream,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return FileListView(files: snapshot.data!.files);
      }
      return LoadingPlaceholder();
    },
  );
}
```

## Key Patterns

### BehaviorSubject (State with Memory)

A BehaviorSubject remembers the last value and broadcasts it to new subscribers:

```dart
final currentUser = BehaviorSubject<AppUser?>();

// Emit a value
currentUser.add(AppUser(name: 'Alice'));

// Subscribe
currentUser.listen((user) {
  print('User: ${user?.name}');  // Immediately prints "User: Alice"
});
```

Use for global state that should be immediately available (user, theme, service URL).

### PublishSubject (Events)

A PublishSubject is a plain event stream with no memory:

```dart
final navigationEvents = PublishSubject<NavigationEvent>();

// Subscribe
navigationEvents.listen((event) {
  print('Navigate to: ${event.route}');
});

// Emit an event
navigationEvents.add(NavigateToEvent('/photos'));
// New subscribers DON'T get this past event
```

Use for transient events (user tapped a button, error occurred).

### RxService Base Class

```dart
// In services/rx_service.dart
abstract class RxService<C, R> {
  /// The observable result stream
  Stream<R> get stream;
  
  /// Invoke the service (usually queries database, makes HTTP call, etc.)
  /// Subclasses override this to define behavior
  Stream<R> invoke();
}
```

Example: **RxFilesPage** (files module):

```dart
class RxFilesPage extends RxService<FilesPageQuery, List<File>> {
  final FileRepository _fileRepository;
  final RxService<FilesPageQuery, List<File>> _rxService = RxService();
  
  @override
  Stream<List<File>> invoke() async* {
    final files = await _fileRepository.getFilesInFolder(folderId);
    yield files;
  }
}
```

When the page needs to refresh (user navigated to a folder, filter changed, etc.), call:

```dart
await rxFilesPage.invoke();
```

This re-runs the query and emits new state to all subscribers.

## Data Flow Example: Filtering Photos

```
User opens Photos app
  ↓
PhotosPage builds
  ↓
StreamBuilder subscribes to PhotosService.stream
  ↓
PhotosService.invoke() queries:
  SELECT * FROM files WHERE mime_type IN (image/jpeg, ...)
  ↓
PhotosService yields List<File>
  ↓
StreamBuilder receives data, rebuilds with photo grid
  ↓
User searches for "sunset"
  ↓
PhotosPage calls PhotosService.applyFilter(PhotoFilter(searchQuery: 'sunset'))
  ↓
PhotosService.invoke() re-runs query:
  SELECT * FROM files WHERE name LIKE '%sunset%' OR ... (semantic search)
  ↓
PhotosService yields new List<File>
  ↓
StreamBuilder rebuilds, grid shows filtered results
```

## Scanner State

Scanner status is observable too:

```dart
// In ScannerManager
class ScannerManager {
  final _scannersRunning = BehaviorSubject<Set<int>>();  // Collection IDs
  
  Stream<bool> get isAnyScanning => _scannersRunning.stream
    .map((ids) => ids.isNotEmpty);
  
  Future<void> start(int collectionId) async {
    _scannersRunning.add({...?_scannersRunning.value, collectionId});
    // ... run scanner isolate ...
    _scannersRunning.add({...?_scannersRunning.value}..remove(collectionId));
  }
}
```

Widgets observe the scanning status:

```dart
// In FilesPage
StreamBuilder<bool>(
  stream: scannerManager.isAnyScanning,
  builder: (context, snapshot) {
    if (snapshot.data ?? false) {
      return SyncingPlaceholder();
    }
    return FileListView();
  },
),
```

## Multi-Tab State Synchronization

When multiple modules (files, email, photos) are open simultaneously, they share the same database but have independent state:

```
Files Page (RxFilesPage)
  └─ files: List<File>
  └─ currentFolder: Folder

Email Page (RxEmailPage)
  └─ emails: List<Email>
  └─ currentFolder: EmailFolder

Photos Page (RxPhotosPage)
  └─ photos: List<File> (filtered by MIME type)
  └─ viewMode: ViewMode (grid, list, timeline, map)
```

When the user deletes a file:

1. **Files Page** calls `fileRepository.deleteFile(id)`
2. **Repository** updates SQLite
3. **RxFilesPage.invoke()** is called to refresh
4. **Photos Page** is NOT automatically notified (independent state)
5. **User must navigate away and back** to Photos page to see the deleted file removed

To make state synchronization automatic, subscribe to database changes:

```dart
class RxPhotosPage {
  final _databaseWatcher = DatabaseChangeWatcher();
  
  @override
  void initState() {
    _databaseWatcher.onChange.listen((_) {
      invoke();  // Re-query and update UI
    });
  }
}
```

But currently, the app relies on manual refresh (user navigates, page rebuilds) rather than global change listeners.

## Performance: Avoiding Over-Subscription

Each subscription to a stream creates a listener. Avoid re-subscribing unnecessarily:

```dart
// ❌ WRONG: Resubscribe on every build
@override
Widget build(BuildContext context) {
  fileList.listen((files) { ... });  // New listener every build!
  return FileListView();
}

// ✅ RIGHT: Subscribe once, use StreamBuilder
@override
Widget build(BuildContext context) {
  return StreamBuilder<List<File>>(
    stream: fileList,  // Single subscription, reused on rebuilds
    builder: (context, snapshot) => FileListView(),
  );
}
```

## Reactive vs. Imperative

MyDataStudio uses a **reactive** model:

```dart
// REACTIVE: Declare what the UI should look like given the current state
StreamBuilder<FilesPageState>(
  stream: rxFilesPage.stream,
  builder: (context, snapshot) {
    if (snapshot.hasError) return ErrorWidget();
    if (snapshot.hasData) return FileListView(files: snapshot.data!.files);
    return LoadingWidget();
  },
);

// When state changes (file added, filter applied, sync completes),
// the UI automatically rebuilds
```

vs. the imperative approach (e.g., traditional MVC):

```dart
// IMPERATIVE: Manually update UI in response to events
void onFileAdded(File file) {
  setState(() {
    _files.add(file);  // Manually update local state
  });
}

void onSyncComplete() {
  _reloadFiles();  // Manually trigger reload
}
```

The reactive approach is cleaner for complex state flows (multiple scanners, multiple pages, async operations).

## Composition: Combining Streams

Combine multiple streams into a single observable result:

```dart
class RxFilesPage {
  late Stream<FilesPageState> stream;
  
  RxFilesPage() {
    // Combine file list and scan status
    stream = Rx.combineLatest2(
      fileRepository.getFiles(),
      scannerManager.isAnyScanning,
      (files, isScanning) => FilesPageState(
        files: files,
        isScanning: isScanning,
      ),
    );
  }
}

// UI receives both files AND sync status
StreamBuilder<FilesPageState>(
  stream: stream,
  builder: (context, snapshot) {
    if (snapshot.data!.isScanning) {
      return SyncingPlaceholder();
    }
    return FileListView(files: snapshot.data!.files);
  },
);
```

## Testing State

In unit tests, emit values and verify subscribers react:

```dart
test('RxFilesPage emits file list after query', () async {
  final rxFilesPage = RxFilesPage(mockRepository);
  
  // Mock the repository to return sample files
  when(mockRepository.getFiles()).thenAnswer((_) async => [file1, file2]);
  
  // Invoke the service
  final states = rxFilesPage.stream.toList();  // Collect emitted states
  await rxFilesPage.invoke();
  
  // Verify the state was emitted
  expect(await states, containsAll([
    isA<List<File>>().having((files) => files.length, 'length', 2),
  ]));
});
```

## Next Steps

- **[Scanning & Sync Lifecycle](./scanning.md)** — How scanners update state
- **[Database Design](../architecture/database.md)** — Where state comes from
- **[Architecture Overview](../architecture/overview.md)** — Global startup state

## Source References

- **Global State**: `/client/lib/main.dart`
- **RxService Base Class**: `/client/lib/services/rx_service.dart`
- **Example RxServices**: `/client/lib/modules/files/services/`, `/client/lib/modules/photos/services/`
- **Scanner State**: `/client/lib/scanners/scanner_manager.dart`
- **Tests**: `/client/test/modules/files/`, `/client/test/modules/photos/`
