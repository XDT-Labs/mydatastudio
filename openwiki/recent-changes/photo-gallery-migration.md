# Photo Gallery Migration (PR #33)

**Commit**: `28041d9` ("feat(photos): migrate photo gallery features to Flutter")

**Status**: Merged to main

## Summary

The Photos module was completely rewritten from a React mockup (Lumina Gallery) into a full-featured Flutter desktop implementation. This major refactor added 4 interactive view modes, album management, metadata editing, and keyboard shortcuts.

## Before & After

### Before
- React mockup with basic grid view only
- No Flutter integration
- No album, tag, or metadata editing features
- ~50 lines of Flutter stub code

### After
- Complete Flutter desktop photo gallery
- 4 view modes: Grid, List, Timeline, Map
- Album management with cover images
- Tag & landmark support (AI-generated via vision model)
- Fullscreen lightbox with zoom, EXIF overlay, slideshow
- Info sidebar with inline title editing
- Batch operations (delete, favorite, album assignment)
- Keyboard shortcuts (20+ global hotkeys)
- ~5,000 lines of new Dart code
- 30+ new tests

## Architecture Changes

### New Database Tables

Added support for photos-specific metadata:

```sql
ALTER TABLE files ADD COLUMN is_favorite INTEGER DEFAULT 0;

CREATE TABLE file_tags (
  id INTEGER PRIMARY KEY,
  file_id INTEGER NOT NULL,
  tag_id INTEGER NOT NULL,
  UNIQUE(file_id, tag_id)
);

CREATE TABLE album (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  cover_file_id INTEGER,
  created_at INTEGER,
  updated_at INTEGER
);

CREATE TABLE album_files (
  id INTEGER PRIMARY KEY,
  album_id INTEGER NOT NULL,
  file_id INTEGER NOT NULL,
  sort_order INTEGER,
  UNIQUE(album_id, file_id)
);
```

### New Service Layer

Created `PhotosService` (RxService-based) to manage:

- **Photo filtering**: By media type, source, location, tags, albums
- **Sorting**: By date, name, size, location
- **Aggregations**: Total storage used, photos per month, favorite counts
- **Batch operations**: Delete, favorite, add to album

```dart
class PhotosService extends RxService<PhotoFilter, List<File>> {
  final PhotosRepository _repo;
  final SelectionService _selectionService;
  final ViewStateService _viewStateService;
  
  @override
  Stream<List<File>> invoke() async* {
    final filter = _viewStateService.currentFilter.value;
    final photos = await _repo.queryPhotos(filter);
    yield photos;
  }
  
  Future<void> applyFilter(PhotoFilter filter) async {
    _viewStateService.currentFilter.add(filter);
    await for (final _ in invoke()) { }
  }
}
```

### Selection & State Management

New services for managing interactive state:

- **SelectionService**: Tracks multi-selected photos (Set<int>)
- **ViewStateService**: Current view mode, active filters, sort order
- **BatchActionService**: Bulk delete, favorite, album operations

## New Widgets (30+)

### View Widgets

- **PhotoGridView**: Responsive grid (2–6 cols) with date grouping
- **PhotoListView**: Sortable table view
- **PhotoTimelineView**: Chronological month-grouped grid with quick-jump sidebar
- **PhotoMapView**: FlutterMap with clustering, polyline routes, playback controls

### Interactive Widgets

- **FullscreenViewer**: Lightbox overlay with zoom, EXIF, slideshow
- **AnimatedInfoPanel**: Slide-in metadata sidebar with inline edit
- **FilterDropdown**: View filters (date range, location, tags, albums)
- **PhotosToolbar**: Search, view mode switcher, batch action buttons

### Sub-Widgets

- **DrawerSection**: Collapsible drawer section (Library, Albums, Tags, etc.)
- **DrawerNavItem**: Single nav item with badge (collection count)
- **StorageMeter**: Disk usage visualization (bar chart)
- **TagChip**: Tag display with delete-on-click
- **DateSectionHeader**: Timeline section header (month/year)
- **PhotoGridTile**: Grid cell with hover overlay

## Key Features

### Grid View
- Responsive 2–6 column layout (auto-adjusts to window width)
- Date-grouped sections with headers
- Hover overlay: Select, favorite, lightbox, location badges
- Lazy-load thumbnails as scroll into view
- Empty state message for no photos

### List View
- Sortable columns: Name, Date, Size, Location, Tags, Albums
- Hover row selection
- Click to open detail/lightbox
- Pagination (50 rows per page)

### Timeline View
- Month-grouped chronological grid
- Quick-jump sidebar (click month to jump)
- Scroll tracking (sidebar highlights current month)
- 500-item batches for smooth scrolling

### Map View
- FlutterMap with CartoDB Dark Matter tiles (free, keyless)
- Zoom-based marker clustering (1000+ pins become 50 clusters at low zoom)
- Chronological polyline (trip route in order of timestamps)
- Trip playback controller:
  - Scrubber to jump to photo timestamp
  - Speed control (0.5x to 4x)
  - Play/pause (animates timeline)

### Lightbox
- Full-screen overlay with zoom controls
- Pan & zoom via mouse/trackpad
- EXIF overlay (camera, ISO, shutter, focal length, GPS)
- Slideshow (3.5s auto-advance, ESC to close)
- Prev/next navigation (arrow keys, buttons)
- Full keyboard control

### Info Sidebar
- Animated slide-in from right edge
- Metadata grid (name, date, size, dimensions, location)
- Inline title editing (click to rename)
- Tag management (add/remove tags)
- Album toggles (add/remove from albums)
- Favorite toggle

### Batch Operations
- Multi-select via checkbox or Ctrl+A
- Toolbar shows count ("47 selected")
- Bulk buttons: Delete, favorite, add to album, copy tags
- Selection preserves across view changes

### Keyboard Shortcuts
- `Space` — Open/close lightbox
- `I` — Toggle info sidebar
- `Escape` — Close lightbox/sidebar
- `F` — Toggle favorite
- `Delete` — Delete selected
- `Ctrl+A` — Select all
- `Left/Right` — Prev/next photo
- `?` — Help modal (list all shortcuts)

## Database Queries

PhotosRepository added ~16 query methods:

```dart
Future<List<File>> getPhotosByDateRange(DateTime from, DateTime to);
Future<List<File>> getPhotosByLocation(int locationId);
Future<List<File>> getFavoritePhotos();
Future<List<File>> getPhotosByTag(int tagId);
Future<List<File>> getPhotosByAlbum(int albumId);
Future<int> getTotalStorageUsed();
Future<Map<String, int>> getPhotosByMonth();
Future<List<Location>> getAvailableLocations();
Future<List<Tag>> getAvailableTags();
// ... and more
```

These queries power the UI's filtering, sorting, and aggregation features.

## Tests Added

Comprehensive test coverage:

```
test/modules/photos/
  pages/
    album_detail_page_test.dart
    photos_app_test.dart
  services/
    batch_action_service_test.dart
    photos_repository_test.dart
    photos_service_test.dart
    selection_service_test.dart
    view_state_service_test.dart
  widgets/
    album_modal_test.dart
    fullscreen_viewer_test.dart
    import_dialog_test.dart
    info_sidebar_test.dart
    keyboard_shortcut_handler_test.dart
    photo_drawer_test.dart
    photo_grid_test.dart
    photo_grid_tile_test.dart
    photo_list_view_test.dart
    photo_map_view_test.dart
    photo_timeline_view_test.dart
    photos_toolbar_test.dart
    shared_widgets_test.dart
    zoom_controller_test.dart
```

Coverage: ~100 tests, most modules at 80%+ coverage

## Integration Points

### Files Module
- Photos are queried from the `files` table (where MIME type is image/*)
- File metadata (EXIF, thumbnails) reused from Files module
- Collections (local FS, Google Drive) appear in Photos drawer

### AI Chat Module
- Semantic search queries can find photos by visual content
- Embedding isolate generates vectors for image contents
- User can search "sunsets" and find visually similar photos

### Email Module
- Email attachments (images) can be viewed in photo gallery
- Photos from email imports appear in timeline view

## Performance Considerations

- **Lazy loading**: Thumbnails load as grid scrolls into view (avoid loading all 1000 thumbnails at once)
- **Batching**: Timeline view loads 500 photos per scroll batch
- **Caching**: Thumbnails cached locally; second view is instant
- **Map clustering**: At low zoom (world view), 10,000 photos become ~100 clusters
- **Vector search**: Embedding generation happens in background (doesn't block UI)

## Breaking Changes

None. The migration is purely additive:

- New database columns are added with `IF NOT EXISTS`
- Existing file queries still work (just filter by MIME type)
- Photos module was not previously available (was just a React mockup)

## Future Enhancements

Backlog items left for future PRs:

- **RAW format support**: Import RAW camera files (CR2, NEF, DNG)
- **Video support**: Gallery views for MP4, MOV, WebM files
- **Face detection**: Auto-group photos by people
- **Smart albums**: Auto-create albums based on rules (e.g., "Vacations 2024")
- **Cloud sync**: Sync album collections to Google Photos
- **Duplicate detection**: Find and merge duplicate photos

## Migration Checklist

For future similar migrations:

- [ ] Create new database tables (with `IF NOT EXISTS`)
- [ ] Add model classes with `fromMap`/`toMap`
- [ ] Create repository with query methods
- [ ] Create RxService for reactive state
- [ ] Build view pages (top-level entry points)
- [ ] Build view mode widgets (grid, list, etc.)
- [ ] Build interactive widgets (lightbox, sidebar, etc.)
- [ ] Add keyboard shortcut handler
- [ ] Implement batch operations
- [ ] Write service tests (80%+ coverage)
- [ ] Write widget tests (smoke tests)
- [ ] Write integration tests (user workflows)
- [ ] Update navigation router
- [ ] Test on device (UI, performance)
- [ ] Write user documentation

## Source References

- **Commit**: `28041d9` on main branch
- **Files Changed**: 50+ new files, ~5,000 new lines
- **Module**: `/client/lib/modules/photos/`
- **Tests**: `/client/test/modules/photos/`
- **Database**: `/client/lib/database_manager.dart` (new tables in schemaDDL)
