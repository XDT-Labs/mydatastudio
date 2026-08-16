# Files & Photos Modules

The **Files** and **Photos** modules provide file browsing, collection management, and photo gallery features. Files is a general-purpose file browser (local + cloud); Photos is a specialized view over the files table with gallery, timeline, and map visualizations.

## Files Module (`/client/lib/modules/files/`)

### Overview

The Files module supports:

- **Local filesystem browsing** via Dart's file API
- **Google Drive browsing** via Google Drive API (OAuth2)
- **File metadata extraction**: EXIF data, thumbnails, file size/type
- **Semantic search**: Embedding-based search across file contents
- **Batch operations**: Delete, favorite, move, etc.

### Directory Structure

```
modules/files/
  pages/
    new_file_collection_page.dart   # Add collection UI (local, Google Drive, coming soon)
    rx_files_page.dart              # Main file browser with tree/table views
  services/
    scanners/
      local_file_isolate.dart        # Local filesystem scanner (isolate)
      google_file_scanner.dart       # Google Drive scanner (isolate)
    repositories/
      file_repository.dart           # File queries
      folder_repository.dart         # Folder hierarchy queries
    batch_file_upsert_service.dart   # Batch insert/update files
    delete_file_service.dart         # Soft-delete + cleanup
    embedding_isolate.dart           # Vector embedding generation (isolate)
    file_upsert_service.dart         # Single file insert/update
    folder_upsert_service.dart       # Folder creation/hierarchy
    get_files_and_folders_service.dart # Fetch from SQLite
    utilities/
      exif_extractor.dart            # EXIF metadata parsing
      thumbnail_cache.dart           # Local thumbnail cache
      thumbnail_generator.dart       # Generate & cache thumbnails
      thumbnail_resolver.dart        # Resolve thumbnail path
  widgets/
    file_collection_setup/           # Google Drive, local FS setup UI
    file_details/
      file_metadata_section.dart     # Display EXIF, file info
      gps_metadata_tab.dart          # Map view for geo-tagged files
      image_preview_widget.dart      # Image preview
      pdf_preview_widget.dart        # PDF preview
      similar_files_tab.dart         # Semantic search for similar files
      text_preview_widget.dart       # Text file preview
      thumbnail_widget.dart          # Display thumbnail
    file_drawer.dart                 # Left sidebar with collections
    file_table.dart                  # Main file list/grid
```

### Scanners: Local & Google Drive

#### LocalFileIsolate

Spawned when a local collection is synced. It:

1. **Walks the filesystem recursively** from the collection root
2. **Extracts metadata**: file size, modified date, MIME type
3. **Generates thumbnails** for images (PIL, RAW format support)
4. **Extracts EXIF** for geo-tagged images
5. **Sends batch upserts** back to main isolate via write relay

Key points:

- **Single-threaded walk**: Avoids overwhelming the I/O
- **Skip hidden files**: Respects `.gitignore` and system hidden files
- **Thumbnail cache**: Stores generated thumbnails in `~/Library/Application Support/<bundle-id>/Thumbnails/`
- **Write relay**: Uses `scan_write_relay.dart` to send batch-file upserts and folder creation back to main isolate

#### GoogleFileIsolate (CloudFileIsolate)

Spawned when a Google Drive collection is synced. It:

1. **Lists files via Google Drive API** (paginated, ~1000 per request)
2. **Extracts metadata**: file size, modified date, MIME type
3. **Downloads headers** for images (to extract EXIF without full download)
4. **Sends upserts** back to main isolate via write relay

Key points:

- **OAuth2 refresh**: Uses stored refresh token to get fresh access token
- **Pagination**: Handles large folders gracefully
- **Stopped on network error**: Retries a few times, then logs and pauses
- **Write relay**: Same pattern as LocalFileIsolate

### File Metadata & Thumbnails

#### EXIF Extraction

`exif_extractor.dart` extracts EXIF data from image files:

```dart
final exifData = await ExifExtractor.extract(filePath);
// Returns: {
//   'latitude': 37.7749,
//   'longitude': -122.4194,
//   'datetime': '2024-01-15 14:30:00',
//   'camera': 'Canon EOS R5',
//   'iso': 400,
//   // ... more fields
// }
```

This data is stored in the `files` table and used in:
- **GPS Metadata Tab**: Interactive map view of geo-tagged files
- **Semantic search**: Vector embeddings of EXIF metadata

#### Thumbnail Generation

`thumbnail_generator.dart` generates cached thumbnails for images:

1. **Load image** via Dart Image library or PIL (for RAW formats)
2. **Resize** to 256px width (maintains aspect ratio)
3. **Encode** as JPEG
4. **Hash** the encoded JPEG to get cache key
5. **Store** in `~/Library/Application Support/<bundle-id>/Thumbnails/<key>.jpg`
6. **Record** `files.thumbnail_key = key` in SQLite

On display, `thumbnail_widget.dart` loads from the cache directory. If the cache miss, it falls back to the original file or a loading placeholder.

### Embedding Generation

`embedding_isolate.dart` is a separate Dart isolate (not per-collection) that:

1. **Watches the `files` table** for rows without an `file_embedding`
2. **Pauses** while any scanner is actively syncing (to avoid contention)
3. **Generates embeddings** in batches (e.g., 100 files at a time)
4. **Sends vectors** back to main isolate via `embedding_message_handler.dart`
5. **Stores** in `file_embedding` table with `resqlite_vector` indexing

This enables **semantic search**: "Find files similar to this one" via nearest-neighbor vector search.

### UI: Files Page

`rx_files_page.dart` is the main file browser. It:

- **Displays a tree view** of folders and a table/grid of files
- **Shows metadata**: name, size, modified date, thumbnail
- **Supports search**: Full-text (by name) and semantic (by content)
- **Previews files**: Image, PDF, text, 3D models, STL, etc.
- **Extracts & displays EXIF**: GPS map, camera info, ISO, shutter speed, etc.
- **Shows similar files**: Semantic search using embedding vectors
- **Supports drag-drop**: Favorite, archive, move files

## Photos Module (`/client/lib/modules/photos/`)

### Overview

**Recently rewritten** (PR #33) from a React mockup to a full Flutter desktop photo gallery. The Photos module is a specialized view over the `files` table with a focus on images, geo-tagging, albums, and interactive browsing.

**Recent addition** (PR #38): Photo clustering by visual similarity using bisecting spherical k-means on image embeddings, with a slider controlling group count and AI-generated group labels.

### Directory Structure

```
modules/photos/
  pages/
    album_detail_page.dart          # Album contents & management
    photos_app.dart                 # Main photo gallery coordinator
  services/
    batch_action_service.dart       # Bulk ops (delete, favorite, etc.)
    photos_repository.dart          # Photo queries (filter, sort, aggregate)
    photos_service.dart             # Gallery state (RxService)
    selection_service.dart          # Multi-select state
    view_state_service.dart         # Active view mode & filters
    clustering/
      spherical_kmeans.dart         # Bisecting k-means clustering core
      photo_cluster_service.dart    # Cluster lifecycle & slider management
      photo_cluster_repository.dart # Cluster persistence & queries
      clustering_isolate.dart       # Background isolate for cluster builds
      cluster_label_service.dart    # AI label generation for cluster groups
  widgets/
    dialogs/
      album_modal.dart              # Create/edit album modal
      import_dialog.dart            # Batch import wizard
      keyboard_shortcuts_modal.dart  # Help modal
    drawer/
      drawer_nav_item.dart          # Single nav item
      drawer_section.dart           # Collapsible section
      storage_meter.dart            # Disk usage visualization
      tag_chip.dart                 # Tag UI
    sidebar/
      animated_info_panel.dart      # Slide-in metadata panel
      info_sidebar.dart             # Wrapper for the sidebar
    tiles/
      date_section_header.dart      # Timeline date header
      photo_grid_tile.dart          # Thumbnail + overlay in grid
    toolbar/
      filter_dropdown.dart          # View filters
      photos_toolbar.dart           # Search, view mode, batch buttons
    viewer/
      fullscreen_viewer.dart        # Lightbox overlay
      zoom_controller.dart          # Pan & zoom logic
    views/
      photo_grid.dart               # Grid view (2-6 cols, date-grouped)
      photo_list_view.dart          # Table view
      photo_map_view.dart           # Map view (FlutterMap, CartoDB tiles)
      photo_timeline_view.dart      # Timeline view (months grouped)
      timeline_quick_jump.dart      # Month/year quick jump sidebar
      trip_playback_controller.dart # Video-like playback (timestamp, speed)
    photo_drawer.dart               # Left nav (Library, Sources, Albums, Tags)
    keyboard_shortcut_handler.dart  # Global hotkeys
  models/
    photo_filter.dart              # Search, media type, sort, source filters
  utils/
    byte_formatter.dart            # Format file sizes (KB, MB, GB)
```

### Four View Modes

#### 1. Grid View

Responsive grid (2–6 columns, auto-layout) with date-grouped sections. Each tile shows:

- **Thumbnail** with hover overlay (select checkbox, favorite star, lightbox icon)
- **Location badge** (if geo-tagged, shows location name from EXIF)
- **Date section header** (groups by month/year)

#### 2. List View

Table view with sortable columns:

- Name, Date, Size, Location, Tags, Albums
- Hover state for row selection
- Click to open detail/lightbox

#### 3. Timeline View

Chronological month-grouped grid with a **quick-jump sidebar** on the right:

- Click month in sidebar to jump to that section
- Scroll position tracked, sidebar highlights current month
- Enables fast navigation for multi-year archives

#### 4. Map View

Interactive map (FlutterMap with CartoDB Dark Matter free tiles):

- **Zoom-based clustering**: Pins cluster at low zoom, expand at high zoom
- **Chronological polyline**: Trip route drawn in order of photo timestamps
- **Trip playback**: Scrubber to jump to photos in sequence, speed control (0.5x to 4x)
- **Geo-filter**: Click location to filter to that area

#### 5. Cluster View (Similarity Grouping)

Photos grouped by visual similarity with AI-generated group labels:

- **Bisecting spherical k-means** clustering over Qwen3-VL image embeddings
- **Group-count slider** (e.g., 4–96 groups) with instant re-grouping
- **Slider stability**: 92% of photos stay in the same group when k increases by 1, avoiding grid churn
- **AI labels**: Vision model names each group from its most representative photos (e.g., "Alpine peaks and rocky terrain", "Wedding ceremonies")
- **Source filtering**: Clusters follow the active source filter (e.g., cluster only a specific collection)
- **Coherence metric**: Centroid distance of each cluster available for validation

**Implementation:**

- `spherical_kmeans.dart` — Pure Dart k-means algorithm (no plugins, runs in isolate or dart CLI)
- `clustering_isolate.dart` — Background isolate spawned on filter change, builds tree asynchronously
- `photo_cluster_repository.dart` — Persists cluster runs to `photo_cluster_runs` and `photo_cluster_assignments` tables
- `photo_cluster_service.dart` — RxService managing slider state, triggering rebuilds on filter change
- `cluster_label_service.dart` — Calls the chat model with representative thumbnails to generate group labels

**Performance:** Full tree build is ~3 seconds for 2,808 photos, linear in photo count (n), logarithmic in group count (k). Re-cutting the tree for a new slider position is microseconds (tree walk only). Tested on real 2,808-photo library; prototype showed subject-level groups (Colosseum exteriors, swans vs. other waterbirds, palace vs. cathedral interiors) at 0.74–0.84 coherence.

**See:** `/docs/plans/photo-clustering.md` for full design and measured behavior.

### Photo Metadata & Albums

#### PhotoFilter Model

Encapsulates search & filter state:

```dart
class PhotoFilter {
  final String? searchQuery;         // Full-text search
  final Set<int>? mediaTypes;        // Image, video, RAW
  final Set<int>? sources;           // Collection IDs
  final SortBy sortBy;               // Date, name, size
  final bool sortAscending;
  final List<int>? locationIds;      // Filter by geo tags
  final List<int>? albumIds;         // Filter by album
  final List<int>? tagIds;           // Filter by tag
}
```

#### Album Management

- **Create album**: Modal to name + add photos
- **Album page**: Shows all photos in album, edit cover, manage members
- **Album metadata**: `album` table with `title`, `description`, `cover_file_id`
- **Album-file mapping**: `album_files` junction table

#### Tags & Landmarks

- **File tags**: `file_tags` junction table (file ↔ tag)
- **Tag UI**: `tag_chip.dart` with delete on click
- **Landmarks**: AI-generated via vision model (stored as tags)

### Interactive Features

#### Lightbox (Fullscreen Viewer)

- **Navigation**: Prev/next, keyboard arrows
- **Zoom**: Mouse wheel or pinch gestures
- **EXIF overlay**: Camera, ISO, shutter, focal length
- **Slideshow**: Auto-advance every 3.5s
- **Keyboard shortcuts**:
  - `Space` — Open/close lightbox
  - `I` — Toggle info sidebar
  - `F` — Toggle favorite
  - `Left/Right` — Prev/next
  - `Escape` — Close

#### Info Sidebar

- **Animated slide-in** from right edge
- **Metadata grid**: Name, date, size, dimensions, location
- **Inline title edit**: Click to rename
- **Tag management**: Add/remove tags
- **Album toggles**: Add/remove from albums

#### Keyboard Shortcuts

Global hotkeys handled by `keyboard_shortcut_handler.dart`:

- `Space` → Open/close lightbox
- `I` → Info sidebar toggle
- `Escape` → Close lightbox/sidebar
- `F` → Toggle favorite
- `Delete` → Delete (in batch mode)
- `Ctrl+A` → Select all (in batch mode)
- `?` → Help modal (list all hotkeys)

### Batch Actions

When in batch-select mode:

- **Toolbar buttons**: Delete, favorite, add to album, copy tags
- **Keyboard shortcuts**: Select all, deselect, delete
- **Status**: Shows count (e.g., "47 selected")
- **Service**: `batch_action_service.dart` coordinates the operations

### Query-Driven UI

`photos_repository.dart` exposes ~16 query methods:

```dart
Future<List<File>> getPhotosByDateRange(DateTime from, DateTime to);
Future<List<File>> getPhotosByLocation(int locationId);
Future<List<File>> getFavoritePhotos();
Future<int> getTotalStorageUsed();
Future<Map<String, int>> getPhotosByMonth();
Future<List<Tag>> getAvailableTags();
// ... and more
```

`photos_service.dart` (RxService) wraps these queries and exposes streams:

```dart
final photoList = BehaviorSubject<List<File>>();
final currentFilter = BehaviorSubject<PhotoFilter>();
final selectedPhotos = BehaviorSubject<Set<int>>();

Future<void> applyFilter(PhotoFilter filter) async {
  final photos = await _repo.queryPhotos(filter);
  photoList.add(photos);
}
```

Widgets subscribe to these streams and automatically update on filter changes.

## Shared Infrastructure

### PhotosRepository

Queries across the `files` table filtered by MIME type:

```dart
const photoMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
  'image/heic',
  'image/raw',
  // ...
};

Future<List<File>> queryPhotos(PhotoFilter filter) async {
  var query = 'SELECT * FROM files WHERE mime_type IN (...)';
  // Apply filter conditions...
  final rows = await db.rawQuery(query);
  return rows.map((row) => File.fromMap(row)).toList();
}
```

### File Collections

Both Files and Photos modules use the same `collection` / `provider` table:

- **Name**: Collection display name
- **Type**: 'local_fs', 'google_drive', 'ssd', etc.
- **Status**: is_scanning (boolean)
- **Credentials**: OAuth tokens (encrypted in vault)

Collections are registered globally and appear in both Files browser and Photos drawer.

## Recent Changes (PR #33)

Commit `28041d9` ("feat(photos): migrate photo gallery features to Flutter") completely rewrote the Photos module:

### Before
- React mockup (Lumina Gallery) with basic grid view only
- No Flutter implementation
- No database schema for albums, tags, etc.

### After
- Full Flutter desktop implementation
- 4 view modes (grid, list, timeline, map)
- Album management with cover images
- Tag & landmark support
- Fullscreen lightbox with EXIF overlay
- Info sidebar with inline editing
- Batch actions (delete, favorite, albums)
- Keyboard shortcuts
- 20+ new tests

### Database Changes
- Added `is_favorite` column to `files`
- Created `file_tags` junction table
- Created `album` table (title, description, cover_file_id)
- Created `album_files` junction table

### Widget Count
- 8 reusable sub-widgets (DrawerSection, StorageMeter, etc.)
- 30+ page/view/dialog components
- 100% test coverage for core services

## Performance Notes

- **Lazy loading**: Grid tiles load thumbnails lazily as they scroll into view
- **Batching**: Semantic search batches queries (e.g., 20 results at a time)
- **Pagination**: Timeline view scrolls smoothly with 500-item batches
- **Map clustering**: Zoom-based clustering reduces marker count at low zoom

## Next Steps

- **[AI Chat](./aichat.md)** — Semantic search across files
- **[Email](./email.md)** — Email module overview
- **[Scanning & Sync](../data-flow/scanning.md)** — How files are discovered and indexed

## Source References

- **Files Module**: `/client/lib/modules/files/`
- **Photos Module**: `/client/lib/modules/photos/`
- **LocalFileIsolate**: `/client/lib/modules/files/services/scanners/local_file_isolate.dart`
- **GoogleFileIsolate**: `/client/lib/modules/files/services/scanners/google_file_scanner.dart`
- **EmbeddingIsolate**: `/client/lib/modules/files/services/embedding_isolate.dart`
- **PhotosRepository**: `/client/lib/modules/photos/services/photos_repository.dart`
- **Recent PR**: Commit `28041d9` — Photo Gallery rewrite (https://github.com/XDT-Labs/mydatatools-desktop/commit/28041d9)
