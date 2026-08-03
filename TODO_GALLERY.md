# Photos Module — Flutter Migration Plan

> **Source:** React "Lumina Gallery" app (`/Users/mikenimer/Development/github/aistudio/photo-gallery/`)
> **Target:** Flutter module replacing `client/lib/modules/photos/` in My Data Studio Desktop
> **Date:** 2026-08-02

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture Decisions](#architecture-decisions)
3. [Phase 0 — Data Layer & Models](#phase-0--data-layer--models)
4. [Phase 1 — Grid View (Core)](#phase-1--grid-view-core)
5. [Phase 2 — Fullscreen Viewer / Lightbox](#phase-2--fullscreen-viewer--lightbox)
6. [Phase 3 — Info Sidebar (Metadata Panel)](#phase-3--info-sidebar-metadata-panel)
7. [Phase 4 — Photos Drawer (Left Navigation)](#phase-4--photos-drawer-left-navigation)
8. [Phase 5 — Header & Toolbar](#phase-5--header--toolbar)
9. [Phase 6 — List View](#phase-6--list-view)
10. [Phase 7 — Timeline View](#phase-7--timeline-view)
11. [Phase 8 — Map View](#phase-8--map-view)
12. [Phase 9 — Album Management](#phase-9--album-management)
13. [Phase 10 — Batch Operations](#phase-10--batch-operations)
14. [Phase 11 — Keyboard Shortcuts & Accessibility](#phase-11--keyboard-shortcuts--accessibility)
15. [Phase 12 — Testing](#phase-12--testing)
16. [Phase 13 — Polish & Integration](#phase-13--polish--integration)
17. [Appendix A — React Component ↔ Flutter Widget Mapping](#appendix-a--react-component--flutter-widget-mapping)
18. [Appendix B — File Inventory](#appendix-b--file-inventory)
19. [Appendix C — Conventions & Patterns](#appendix-c--conventions--patterns)

---

## Overview

The React "Lumina Gallery" is a photo gallery mockup built with React 19, TypeScript, Vite, and Tailwind CSS v4. It features **four view modes** (Grid, List, Timeline, Map), a **fullscreen lightbox** with zoom/slideshow, an **info sidebar** with EXIF display and tag editing, **album management**, **batch operations**, **keyboard shortcuts**, and **multi-source filtering** (local, cloud drives, email).

The goal is to rewrite this as a native Flutter module that:
- Replaces the existing `client/lib/modules/photos/` module entirely
- Uses the app's existing **"High-Tech Zen" dark theme** (not the React app's Tailwind styles)
- Uses **RxDart** for state management (matching the app's `RxService` pattern)
- Pulls **real data** from SQLite via existing repository patterns
- Integrates with **all existing data sources** (local files, Google Drive, Gmail, Yahoo, Outlook, etc.)
- Reuses existing **shared widgets** (`AdaptiveAppBar`, `NavigationWrapper`, `CollapsingDrawer`, `AccessibleTap`)

---

## Architecture Decisions

| Decision | Choice | Rationale |
|---|---|---|
| State Management | **RxDart** (`BehaviorSubject` / `RxService<C,R>`) | App-wide convention; all modules use this pattern |
| Routing | **go_router** (existing `AppRouter`) | Already configured; photos route at `/photos` |
| Theme | **Existing dark theme** (Material 3 `ColorScheme`) | Obsidian base `#141317`, lavender primary `#E8DDFF`, Montserrat/Public Sans/Inter fonts |
| Database | **resqlite** raw SQL | Matches existing `PhotosRepository` and `DatabaseManager` patterns |
| Image loading | **ThumbnailResolver** → `ProgressiveImage` | Already handles cache keys, network URLs, base64, and fallbacks |
| Map engine | **flutter_map** + OpenStreetMap/CartoDB tiles | Flutter-native Leaflet alternative; supports custom markers and polylines |
| Grid layout | **flutter_staggered_grid_view** or custom `SliverGrid` | Virtualized, responsive, performant for large photo libraries |
| Video playback | **media_kit** (already in pubspec) | Already initialized in `main.dart` |
| EXIF reading | **native_exif** (already in pubspec) | Already a dependency |

---

## Phase 0 — Data Layer & Models

> **Goal:** Build the data foundation that all views consume. Create service classes, models, and repository methods.

### Task 0.1 — Photo Filter Model

**File:** `client/lib/modules/photos/models/photo_filter.dart`

Create a Dart model equivalent to the React `FilterOptions` type:

```dart
class PhotoFilter {
  final String searchQuery;
  final String? mediaType;        // 'photo', 'video', or null (all)
  final String? source;           // collection type filter (e.g., 'local', 'gdrive', 'email')
  final String? albumId;
  final String? tag;
  final String? location;         // "City, Country" string
  final bool onlyFavorites;
  final PhotoSortOrder sortBy;
}

enum PhotoSortOrder { dateDesc, dateAsc, title, size }
```

### Task 0.2 — Favorites Support (Database Migration)

The React app has a `favorite` boolean on each `MediaItem`. The existing `files` table does **not** have a `favorite` column.

**Action:** Add an `ALTER TABLE files ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0` migration in `DatabaseManager`.

**File to modify:** `client/lib/database_manager.dart` (add migration in `_runMigrations()`)

### Task 0.3 — Tags Support (Database Table)

The React app has per-item `tags: string[]`. The existing schema has no tags table.

**Action:** Create a `file_tags` junction table:

```sql
CREATE TABLE IF NOT EXISTS file_tags (
  file_id TEXT NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY (file_id, tag),
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_file_tags_tag ON file_tags(tag);
```

**File:** `client/lib/database_manager.dart`

### Task 0.4 — Album–File Junction Table

The existing `albums` table only has `id` and `name`. We need a junction table to associate files with albums.

**Action:** Create:
```sql
CREATE TABLE IF NOT EXISTS album_files (
  album_id TEXT NOT NULL,
  file_id TEXT NOT NULL,
  PRIMARY KEY (album_id, file_id),
  FOREIGN KEY (album_id) REFERENCES albums(id) ON DELETE CASCADE,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
);
```

Also add `description TEXT` and `cover_file_id TEXT` columns to `albums` table.

**File:** `client/lib/database_manager.dart`

### Task 0.5 — Photos Repository (Enhanced)

**File:** `client/lib/modules/photos/services/photos_repository.dart` (rewrite)

Expand the existing repository with these query methods:

| Method | Returns | Description |
|---|---|---|
| `photos({PhotoFilter? filter})` | `Future<List<File>>` | Filtered, sorted query with joins for tags, albums, favorites |
| `photosByDate({PhotoFilter? filter})` | `Future<Map<String, List<File>>>` | Grouped by `yyyy-MM-dd`, filtered |
| `photosByMonth({PhotoFilter? filter})` | `Future<Map<String, List<File>>>` | Grouped by `yyyy-MM` for timeline view |
| `photosWithLocation({PhotoFilter? filter})` | `Future<List<File>>` | Only files with non-null `latitude` AND `longitude` |
| `allTags()` | `Future<Map<String, int>>` | Tag → usage count map |
| `allLocations()` | `Future<Map<String, int>>` | "City, Country" → count map (requires new `city`/`country` columns or derivation from lat/lng) |
| `sourceCountsByType()` | `Future<Map<String, int>>` | Collection type → file count |
| `toggleFavorite(String fileId)` | `Future<void>` | Toggle `is_favorite` |
| `addTag(String fileId, String tag)` | `Future<void>` | Insert into `file_tags` |
| `removeTag(String fileId, String tag)` | `Future<void>` | Delete from `file_tags` |
| `getTagsForFile(String fileId)` | `Future<List<String>>` | Query file's tags |
| `addFileToAlbum(String fileId, String albumId)` | `Future<void>` | Insert into `album_files` |
| `removeFileFromAlbum(String fileId, String albumId)` | `Future<void>` | Delete from `album_files` |
| `getAlbumsForFile(String fileId)` | `Future<List<Album>>` | Albums a file belongs to |
| `createAlbum(Album album)` | `Future<void>` | Insert album with description & cover |
| `deleteAlbum(String albumId)` | `Future<void>` | Cascade deletes album_files rows |
| `storageUsage()` | `Future<({int usedBytes, int totalBytes})>` | Sum of `size` column; total from config |

All queries must:
- Apply `is_inline = 0` exclusion (skip email tracking pixels)
- Apply `content_type LIKE 'image/%'` or video MIME filters based on `PhotoFilter.mediaType`
- Support search across `name`, `path`, tags (via JOIN), and location fields
- Respect `is_deleted = 0` (skip trashed files)

### Task 0.6 — Photos Service (RxDart)

**File:** `client/lib/modules/photos/services/photos_service.dart` (new, replaces `photos_by_date_service.dart`)

Create a comprehensive `PhotosService extends RxService<PhotosServiceCommand, List<File>>` with:

```dart
class PhotosServiceCommand extends RxCommand {
  final PhotoFilter filter;
}

class PhotosService extends RxService<PhotosServiceCommand, List<File>> {
  static PhotosService get instance => _instance;
  
  // Additional streams for derived data
  final BehaviorSubject<Map<String, List<File>>> photosByDate;
  final BehaviorSubject<Map<String, List<File>>> photosByMonth;
  final BehaviorSubject<List<File>> photosWithLocation;
  final BehaviorSubject<Map<String, int>> tagCounts;
  final BehaviorSubject<Map<String, int>> locationCounts;
  final BehaviorSubject<Map<String, int>> sourceCounts;
}
```

### Task 0.7 — Selection Service

**File:** `client/lib/modules/photos/services/selection_service.dart`

Manages multi-select state (equivalent to React's `selectedIds`):

```dart
class SelectionService {
  static SelectionService get instance => _instance;
  
  final BehaviorSubject<Set<String>> selectedIds;
  final BehaviorSubject<bool> isSelectionMode;
  
  void toggle(String fileId);
  void selectAll(List<String> fileIds);
  void deselectAll();
  void selectRange(String fromId, String toId, List<File> orderedFiles);
}
```

### Task 0.8 — View State Service

**File:** `client/lib/modules/photos/services/view_state_service.dart`

Manages which view mode is active and sidebar states:

```dart
enum PhotoViewMode { grid, list, timeline, map }

class ViewStateService {
  static ViewStateService get instance => _instance;
  
  final BehaviorSubject<PhotoViewMode> viewMode;
  final BehaviorSubject<File?> infoMedia;       // Currently inspected file
  final BehaviorSubject<bool> isInfoOpen;        // Right sidebar visibility
  final BehaviorSubject<File?> lightboxMedia;    // Currently viewed in lightbox
  final BehaviorSubject<PhotoFilter> activeFilter;
  final BehaviorSubject<String> activeNav;       // 'all', 'favorites', 'videos', etc.
}
```

---

## Phase 1 — Grid View (Core)

> **Goal:** Replace the existing basic `Wrap` layout with a performant, virtualized, date-grouped photo grid.
> **React equivalent:** `MediaGrid.tsx`

### Task 1.1 — PhotosApp Page (Rewrite)

**File:** `client/lib/modules/photos/pages/photos_app.dart` (rewrite)

The main page widget that orchestrates the view layout:

```
┌──────────────────────────────────────────────────┐
│ PhotosToolbar (search, filters, view switcher)   │
├──────┬───────────────────────────┬───────────────┤
│      │                           │               │
│ Left │   Active View             │  Info Sidebar  │
│Drawer│   (Grid/List/Timeline/Map)│  (conditional) │
│      │                           │               │
├──────┴───────────────────────────┴───────────────┤
│ Status Bar (item count, keyboard hints)          │
└──────────────────────────────────────────────────┘
```

- Subscribe to `ViewStateService.viewMode` and render the appropriate view widget
- Subscribe to `PhotosService.sink` for the media list
- Subscribe to `ViewStateService.isInfoOpen` to conditionally show right panel
- Wire up the `NavigationWrapper` shell (already configured in router)

### Task 1.2 — PhotoGrid Widget

**File:** `client/lib/modules/photos/widgets/views/photo_grid.dart`

Features to implement:
- **Date grouping:** Group files by month/year with sticky section headers (e.g., "July 2026", "June 2026")
- **Responsive columns:** Adapt column count based on available width:
  - `< 600px`: 2 columns
  - `< 900px`: 3 columns  
  - `< 1200px`: 4 columns
  - `< 1500px`: 5 columns
  - `≥ 1500px`: 6 columns
- **Virtualization:** Use `CustomScrollView` with `SliverList` + `SliverGrid` per date group for smooth scrolling with thousands of items
- **Aspect ratio:** Square tiles (`aspectRatio: 1.0`) like the React grid
- **Lazy image loading:** Render thumbnails via `ThumbnailResolver.providerFor()` with `ProgressiveImage`
- **Empty state:** Show centered message with icon when no photos match filters

### Task 1.3 — PhotoGridTile Widget

**File:** `client/lib/modules/photos/widgets/tiles/photo_grid_tile.dart`

Individual grid cell with hover interactions (equivalent to React `MediaGrid` card overlays):

- **Base:** Square thumbnail with rounded corners (`BorderRadius.circular(4)`)
- **Hover overlay (mouse enter):**
  - Top-left: Selection checkbox (circle → checked circle)
  - Top-right: Favorite heart toggle button
  - Bottom-left: Video duration badge (if video, show `▶ 0:32`)
  - Bottom-left: Location badge (`📍 City`)
  - Bottom-right: Quick actions (fullscreen icon, download icon)
- **Selection state:** Blue border + dimmed overlay when selected
- **On tap:** Open fullscreen lightbox (`ViewStateService.lightboxMedia.add(file)`)
- **On right-click / long press:** Context menu (Open, Info, Add to Album, Favorite, Download, Delete)

### Task 1.4 — Date Section Header Widget

**File:** `client/lib/modules/photos/widgets/tiles/date_section_header.dart`

Sticky header for each date group:
- Display formatted date (e.g., "Saturday, July 12, 2026")
- Show item count for the group
- Optional "Select All in Group" checkbox for batch operations

---

## Phase 2 — Fullscreen Viewer / Lightbox

> **Goal:** Full-resolution image viewing with zoom, navigation, slideshow, and EXIF overlay.
> **React equivalent:** `FullscreenViewer.tsx`

### Task 2.1 — FullscreenViewer Widget

**File:** `client/lib/modules/photos/widgets/viewer/fullscreen_viewer.dart`

Full-screen overlay (`Overlay` or `Navigator.push` with `PageRouteBuilder` for fade transition):

**Layout:**
```
┌──────────────────────────────────────────────────┐
│ [1/24] [Slideshow] [Zoom-/+/Reset] [Info] [♥] [↓] [✕] │  ← Top bar
├──────────────────────────────────────────────────┤
│                                                  │
│  [◀]         Zoomable Image / Video          [▶] │  ← Main content
│                                                  │
├──────────────────────────────────────────────────┤
│ ┌─ EXIF Info Overlay (togglable) ──────────────┐ │
│ │ Title | Format | Size | Location | Date | Cam │ │
│ └──────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────┘
```

**Features:**
- **Image display:** Full-resolution image via `InteractiveViewer` for pinch-to-zoom and pan
- **Zoom controls:** Zoom level 0.5x to 3.0x (step 0.25x), with +/- buttons and reset
- **Navigation:** Left/right arrows to move through `filteredMedia` list, with preloading of adjacent images
- **Slideshow mode:** Auto-advance every 3.5 seconds with play/pause toggle
- **Video support:** Use `media_kit` `Video` widget with playback controls for video files
- **EXIF overlay:** Translucent bottom bar showing title, format, file size, location, date, camera model (toggle with 'i' key)
- **Close:** ESC key or X button returns to grid

### Task 2.2 — Zoom Controller

**File:** `client/lib/modules/photos/widgets/viewer/zoom_controller.dart`

Reusable zoom state management:
```dart
class ZoomController extends ChangeNotifier {
  double zoomLevel = 1.0;
  static const double minZoom = 0.5;
  static const double maxZoom = 3.0;
  static const double step = 0.25;
  
  void zoomIn();
  void zoomOut();
  void reset();
}
```

---

## Phase 3 — Info Sidebar (Metadata Panel)

> **Goal:** Right slide-over panel for viewing/editing photo metadata, tags, and album memberships.
> **React equivalent:** `InfoSidebar.tsx`

### Task 3.1 — InfoSidebar Widget

**File:** `client/lib/modules/photos/widgets/sidebar/info_sidebar.dart`

Fixed-width right panel (`width: 320`) that slides in/out with animation:

**Sections (top to bottom):**

1. **Header bar:** Close button (X) + "Details" title
2. **Preview card:** Aspect-ratio thumbnail (tap opens lightbox); for video, show video player with controls
3. **Editable title:** Inline text editing with save on submit (updates `files.name` in DB)
4. **Editable description:** Multi-line text area (requires new `description` column on `files` table — or store in metadata)
5. **EXIF data grid:** Two-column layout showing:
   - Dimensions (from content or EXIF)
   - File Size (formatted: KB/MB/GB)
   - Camera model (from EXIF if available)
   - Location (City, Country — derived from lat/lng or raw coordinates)
   - Date Taken
   - Content Type
   - Source (collection name + icon)
6. **Tags section:**
   - Display existing tags as removable chips/pills
   - "Add tag" input field with autocomplete from existing tags
   - Tags saved to `file_tags` junction table
7. **Album membership:**
   - Checkbox list of all albums
   - Checked = file belongs to that album
   - Toggle inserts/removes from `album_files`
8. **Actions:**
   - "Download Original" button (copy file or open in Finder)
   - "Delete Photo" button (set `is_deleted = 1`, confirm dialog)

### Task 3.2 — AnimatedInfoPanel Wrapper

**File:** `client/lib/modules/photos/widgets/sidebar/animated_info_panel.dart`

Animated container that slides in from the right edge with a `SlideTransition` + `SizeTransition`:
- Subscribe to `ViewStateService.isInfoOpen`
- Animate width from 0 → 320 over 250ms ease-in-out
- When open, the main content area shrinks to accommodate

---

## Phase 4 — Photos Drawer (Left Navigation)

> **Goal:** Module-specific left drawer for filtering by source, library section, albums, tags, and locations.
> **React equivalent:** `Sidebar.tsx`

### Task 4.1 — PhotoDrawer Widget (Rewrite)

**File:** `client/lib/modules/photos/widgets/photo_drawer.dart` (rewrite)

Uses the existing `CollapsingDrawer` pattern. Sections:

1. **Library** (always visible):
   - All Photos (icon: `Icons.photo_library`) — count badge
   - Favorites (icon: `Icons.favorite`) — count badge
   - Videos (icon: `Icons.videocam`) — count badge

2. **Sources** (collapsible, default expanded):
   - Local Folders — count badge per collection of type 'local'
   - Google Drive — count badge per 'gdrive' collection
   - Dropbox — count badge (future, show if collections exist)
   - iCloud — count badge (future)
   - Email Attachments — count badge per email scanner collections
   - Each source item filters by `collection_id`

3. **Albums** (collapsible):
   - List of user-created albums with item counts
   - Each album item has hover delete button
   - "+ Create Album" button at bottom → opens `AlbumModal`

4. **Tags** (collapsible):
   - Tag cloud or list showing `#tag (count)` entries
   - Tap to filter by tag

5. **Locations** (collapsible):
   - List of "City, Country" entries with pin icon and counts
   - Tap to filter by location

6. **Storage Meter** (bottom):
   - Progress bar showing used vs. total storage
   - Text: "X.X GB of Y GB"

7. **Clear Filters** button (visible when any filter is active)

### Task 4.2 — Drawer Item Widgets

**Files:**
- `client/lib/modules/photos/widgets/drawer/drawer_section.dart` — Collapsible section with header + expand/collapse
- `client/lib/modules/photos/widgets/drawer/drawer_nav_item.dart` — Individual nav item with icon, label, count badge, active state
- `client/lib/modules/photos/widgets/drawer/storage_meter.dart` — Linear progress bar with label
- `client/lib/modules/photos/widgets/drawer/tag_chip.dart` — Compact tag display with count

---

## Phase 5 — Header & Toolbar

> **Goal:** Top toolbar with search, filter controls, view mode switcher, and batch action bar.
> **React equivalent:** `Header.tsx`

### Task 5.1 — PhotosToolbar Widget

**File:** `client/lib/modules/photos/widgets/toolbar/photos_toolbar.dart`

**Note:** This sits **below** the existing `AdaptiveAppBar` (which is part of `NavigationWrapper`). This is a module-specific toolbar row.

**Normal mode (no selection):**
```
[🔍 Search...] [Filter ▾] [Spacer] [Grid|List|Timeline|Map] [⬆ Upload] [⌨ Shortcuts]
```

- **Search field:** Text input that updates `PhotoFilter.searchQuery` with debounce (300ms)
- **Filter dropdown:** Popup menu with:
  - Type: All / Photos / Videos (radio)
  - Favorites only toggle
  - Sort: Date (newest), Date (oldest), Title, Size
- **View mode switcher:** `SegmentedButton` or `ToggleButtons` for Grid/List/Timeline/Map icons
- **Upload button:** Opens file picker dialog (for local import)
- **Keyboard shortcuts button:** Opens shortcuts modal

**Batch mode (selectedIds.length > 0):**
```
[✓ N selected] [Select All] [Deselect] [Spacer] [Add to Album] [↓ Download] [🗑 Delete]
```

- Replaces the normal toolbar content when selection is active
- Background color change to indicate batch mode (use `theme.colorScheme.primaryContainer`)

### Task 5.2 — FilterDropdown Widget

**File:** `client/lib/modules/photos/widgets/toolbar/filter_dropdown.dart`

Popup overlay anchored to the filter button:
- Media type radio group (All / Photos / Videos)
- "Favorites only" switch
- Sort order dropdown
- Apply / Reset buttons

---

## Phase 6 — List View

> **Goal:** Tabular view showing detailed metadata per file in a scrollable table.
> **React equivalent:** `MediaList.tsx`

### Task 6.1 — PhotoListView Widget

**File:** `client/lib/modules/photos/widgets/views/photo_list_view.dart`

Scrollable list (not `DataTable` — use `ListView.builder` for virtualization):

**Columns:**
| # | Column | Width | Content |
|---|---|---|---|
| 1 | Thumbnail + Title | flex | 40px thumbnail, filename, source path subtext, selection checkbox |
| 2 | Date | 140px | Calendar icon + formatted date |
| 3 | Location | 160px | Pin icon + City, Country |
| 4 | Camera / Details | 200px | Camera model, resolution, file size |
| 5 | Actions | 120px | Favorite toggle, lightbox button, download button |

**Features:**
- Column header row with sort indicators (click to sort)
- Row hover highlighting (`surfaceContainerHigh` color)
- Active selection styling (border accent color)
- Row click opens info sidebar, double-click opens lightbox
- Keyboard navigation (up/down arrows)

---

## Phase 7 — Timeline View

> **Goal:** Chronological timeline with month groupings and a floating quick-jump sidebar.
> **React equivalent:** `MediaTimeline.tsx`

### Task 7.1 — PhotoTimelineView Widget

**File:** `client/lib/modules/photos/widgets/views/photo_timeline_view.dart`

**Layout:**
```
┌────────────────────────────────────────────┬────┐
│                                            │ J  │
│  ── July 2026 ──────────────────────────   │ J  │
│  [grid of photos for July]                 │ M  │
│                                            │ A  │
│  ── June 2026 ──────────────────────────   │ M  │
│  [grid of photos for June]                 │ F  │
│                                            │ J  │
│  ── May 2026 ───────────────────────────   │ ...│
│  [grid of photos for May]                  │    │
└────────────────────────────────────────────┴────┘
           Main Scroll Area              Quick Jump
```

**Features:**
- Group by year + month with sticky section headers
- Each section contains a responsive grid of photo tiles (reuse `PhotoGridTile`)
- Smooth scroll animation when tapping quick-jump entries

### Task 7.2 — TimelineQuickJump Widget

**File:** `client/lib/modules/photos/widgets/views/timeline_quick_jump.dart`

Fixed-position vertical bar on the right edge:
- Lists month abbreviations (e.g., "Jul", "Jun") with photo counts
- Clicking smoothly scrolls the main `ScrollController` to the corresponding section
- Highlights the currently visible month
- Use `ScrollController.addListener` to track visible section

---

## Phase 8 — Map View

> **Goal:** Interactive map showing geotagged photos with custom markers, clustering, route lines, and trip playback.
> **React equivalent:** `MediaMap.tsx`

### Task 8.1 — Dependencies

Add to `client/pubspec.yaml`:
```yaml
dependencies:
  flutter_map: ^7.0.0          # Leaflet-based map widget
  latlong2: ^0.9.0             # LatLng model
  flutter_map_marker_cluster: ^2.0.0  # Marker clustering
```

### Task 8.2 — PhotoMapView Widget

**File:** `client/lib/modules/photos/widgets/views/photo_map_view.dart`

**Features:**
- **Map tiles:** CartoDB Dark Matter (`https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png`) — **free, no API key required**. These are community basemaps hosted by CARTO with no subscription or signup needed. Matches the app's dark theme perfectly.
  > **Future upgrade path:** If higher reliability or richer features are needed later, swap to Google Maps (`google_maps_flutter` with dark JSON styling — requires a Google Maps API key, free tier covers ~28k loads/month) or MapTiler Dark (free tier, requires key signup).
- **Data source:** Subscribe to `PhotosService.photosWithLocation` (only files with non-null lat/lng)
- **Custom photo markers:** Circular thumbnail markers (40px diameter) with colored border glow using the app's primary color
- **Marker clustering:** At low zoom levels (`< 8`), group nearby markers into cluster circles showing count
- **Route polyline:** Dashed blue line connecting chronologically-sorted photo locations
- **Marker tap:** Opens info sidebar for the tapped photo
- **Auto-fit bounds:** On load, fit map to show all markers with padding

### Task 8.3 — Trip Playback Controller

**File:** `client/lib/modules/photos/widgets/views/trip_playback_controller.dart`

Floating overlay bar at the bottom of the map view:

```
[▶/⏸] [⏮ Reset] [Speed: 1x ▾] [━━━●━━━━━━━ Progress] [Photo: "Sunset.jpg" 📍 Tokyo]
```

**Features:**
- **Play/Pause:** Animate through photos chronologically, panning map to each location
- **Speed selector:** 1x, 2x, 4x playback speeds
- **Progress slider:** Draggable progress indicator
- **Active photo preview:** Show thumbnail + title + location of current playback position
- **Pulse animation:** Animated ping on the active marker during playback
- Use `Timer.periodic` for playback advancement; animate map pan with `MapController.move()`

---

## Phase 9 — Album Management

> **Goal:** Create, browse, and manage photo albums.
> **React equivalent:** `AlbumModal.tsx`

### Task 9.1 — AlbumModal Dialog

**File:** `client/lib/modules/photos/widgets/dialogs/album_modal.dart`

Modal dialog (`showDialog`) with two tabs/modes:

**Mode 1 — "Add to Existing Album":**
- List of existing albums with radio selection
- "Add" button adds all `selectedIds` to chosen album

**Mode 2 — "Create New Album":**
- Title text field (required)
- Description text field (optional)
- Cover image auto-selected from first selected item
- "Create & Add" button creates album and assigns selected files

### Task 9.2 — Album Detail Page

**File:** `client/lib/modules/photos/pages/album_detail_page.dart`

When navigating into an album from the drawer:
- Shows the album's photos in the currently selected view mode (grid/list/timeline)
- Header displays album title, description, cover image, and item count
- "Edit Album" and "Delete Album" actions
- Route: `/photos/albums/:albumId`

---

## Phase 10 — Batch Operations

> **Goal:** Multi-select files and perform bulk actions.
> **React equivalent:** Batch toolbar in `Header.tsx`

### Task 10.1 — Batch Action Service

**File:** `client/lib/modules/photos/services/batch_action_service.dart`

```dart
class BatchActionService {
  Future<void> downloadSelected(Set<String> fileIds);     // Copy to Downloads or user-chosen folder
  Future<void> deleteSelected(Set<String> fileIds);       // Set is_deleted=1, confirm dialog
  Future<void> favoriteSelected(Set<String> fileIds);     // Toggle is_favorite
  Future<void> addToAlbum(Set<String> fileIds, String albumId);
  Future<void> removeFromAlbum(Set<String> fileIds, String albumId);
}
```

### Task 10.2 — Selection Interactions

Implement across all views:
- **Single click:** Select/deselect individual item
- **Shift+click:** Range select (from last selected to clicked item)
- **Ctrl/Cmd+click:** Toggle single item without clearing others
- **Checkbox click:** Toggle without opening lightbox
- **"Select All" in toolbar:** Selects all currently filtered items
- **Visual feedback:** Blue border + checkmark overlay on selected tiles

---

## Phase 11 — Keyboard Shortcuts & Accessibility

> **Goal:** Full keyboard navigation and screen reader support.
> **React equivalent:** `KeyboardShortcutsModal.tsx` + keyboard handlers throughout

### Task 11.1 — Keyboard Shortcut Handler

**File:** `client/lib/modules/photos/widgets/keyboard_shortcut_handler.dart`

Wrap the photos module in a `FocusableActionDetector` or `Shortcuts` + `Actions` widget:

| Key | Action | Context |
|---|---|---|
| `Space` | Open lightbox for focused item | Grid/List/Timeline |
| `I` | Toggle info sidebar | Anywhere in photos |
| `Escape` | Close lightbox / info sidebar / modal | Anywhere |
| `←` / `→` | Previous / Next photo | Lightbox |
| `↑` / `↓` | Navigate items | Grid/List |
| `+` / `=` | Zoom in | Lightbox |
| `-` | Zoom out | Lightbox |
| `F` | Toggle favorite | When item is focused/viewed |
| `Delete` / `Backspace` | Delete selected | When items selected |
| `Ctrl+A` / `Cmd+A` | Select all | Grid/List/Timeline |
| `?` | Show keyboard shortcuts modal | Anywhere in photos |

### Task 11.2 — KeyboardShortcutsModal Widget

**File:** `client/lib/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart`

Simple dialog listing all shortcuts in a two-column table (Key | Action).

### Task 11.3 — Accessibility

- Wrap interactive elements with `Semantics` widgets (labels, hints)
- Use the existing `AccessibleTap` widget for custom tap targets
- Ensure all buttons have tooltips
- Support screen reader navigation order
- Focus indicators visible on all interactive elements

---

## Phase 12 — Testing

> **Goal:** Comprehensive test coverage following the project's TDD conventions.

### Task 12.1 — Unit Tests (Services & Repository)

**Directory:** `client/test/modules/photos/services/`

| Test File | Tests |
|---|---|
| `photos_repository_test.dart` | All query methods, filter combinations, sort orders, edge cases (empty results, invalid filters) |
| `photos_service_test.dart` | Stream emissions, loading states, filter updates, error handling |
| `selection_service_test.dart` | Select/deselect, range select, select all, clear |
| `view_state_service_test.dart` | View mode changes, sidebar toggle, lightbox state |
| `batch_action_service_test.dart` | Download, delete, favorite batch operations |

### Task 12.2 — Widget Tests

**Directory:** `client/test/modules/photos/widgets/`

| Test File | Tests |
|---|---|
| `photo_grid_test.dart` | Renders grid, date grouping, responsive columns, empty state |
| `photo_grid_tile_test.dart` | Hover overlay, selection state, tap handlers, favorite toggle |
| `fullscreen_viewer_test.dart` | Opens/closes, navigation arrows, zoom, slideshow, keyboard |
| `info_sidebar_test.dart` | Opens/closes, displays metadata, tag editing, album checkboxes |
| `photo_drawer_test.dart` | Sections render, counts correct, filter on tap, collapse/expand |
| `photos_toolbar_test.dart` | Search input, filter dropdown, view switcher, batch mode |
| `photo_list_view_test.dart` | Column rendering, sort, row interactions |
| `photo_timeline_view_test.dart` | Month grouping, quick jump scroll |
| `photo_map_view_test.dart` | Map renders, markers placed, clustering |
| `album_modal_test.dart` | Create album, add to album, validation |

### Task 12.3 — Integration Tests

**Directory:** `client/integration_test/photos/`

| Test | Scenario |
|---|---|
| `gallery_navigation_test.dart` | Navigate between all 4 view modes |
| `photo_lifecycle_test.dart` | Browse → select → view fullscreen → favorite → add to album → delete |
| `search_and_filter_test.dart` | Search by name, filter by type, filter by source, sort order changes |

---

## Phase 13 — Polish & Integration

> **Goal:** Final integration, theming alignment, and performance optimization.

### Task 13.1 — Theme Compliance

Verify all new widgets use **only** the app's theme tokens:
- Colors: `Theme.of(context).colorScheme.*` — never hardcoded hex values
- Typography: `Theme.of(context).textTheme.*` with Montserrat for headers, Public Sans for body, Inter for data tables
- Spacing: Consistent 8px grid system
- Borders: Follow "No-Line Rule" (transparent dividers)
- Elevation: Use `surfaceContainer*` hierarchy, not shadows

### Task 13.2 — Glassmorphism (Stretch Goal)

Per the existing `TODO.md`, extract the glass treatment into a reusable `GlassPanel` widget and apply it to:
- Info sidebar background
- Filter dropdown overlay
- Lightbox top/bottom bars
- Quick jump sidebar

### Task 13.3 — Performance Optimization

- **Image cache:** Verify `PaintingBinding.instance.imageCache.maximumSizeBytes = 300MB` is sufficient
- **Grid virtualization:** Confirm `SliverGrid` properly recycles off-screen tiles
- **Thumbnail preloading:** Preload thumbnails for the next page of results during scroll idle
- **Map marker limits:** Cap visible markers at ~500; show clustering beyond that
- **Isolate-safe queries:** Ensure large queries don't block the UI thread (use `compute()` for grouping/sorting if needed)

### Task 13.4 — Router Updates

**File:** `client/lib/app_router.dart`

Update the photos route to support sub-routes:

```dart
GoRoute(
  path: '/photos',
  pageBuilder: (context, state) => RoutePage(
    body: NavigationWrapper(
      body: PhotosApp(),
      drawer: PhotoDrawer(),
    ),
  ),
  routes: [
    GoRoute(
      path: 'albums/:albumId',
      pageBuilder: (context, state) => RoutePage(
        body: NavigationWrapper(
          body: AlbumDetailPage(albumId: state.pathParameters['albumId']!),
          drawer: PhotoDrawer(),
        ),
      ),
    ),
  ],
),
```

### Task 13.5 — Status Bar Integration

Update the bottom status bar (in `PhotosApp`) to show:
- Total item count for current filter: "247 photos, 12 videos"
- Active keyboard hints: `SPACE: View` · `I: Info` · `ESC: Close`
- Selection count when in batch mode: "5 items selected"

### Task 13.6 — Delete Existing Files

Remove deprecated files after migration is complete:
- `client/lib/modules/photos/services/photos_by_date_service.dart` (replaced by `photos_service.dart`)

---

## Appendix A — React Component ↔ Flutter Widget Mapping

| React Component | Flutter Widget | File |
|---|---|---|
| `App.tsx` + `GalleryContext.tsx` | `PhotosApp` + `PhotosService`/`ViewStateService` | `pages/photos_app.dart`, `services/*.dart` |
| `Header.tsx` | `PhotosToolbar` | `widgets/toolbar/photos_toolbar.dart` |
| `Sidebar.tsx` | `PhotoDrawer` | `widgets/photo_drawer.dart` |
| `MediaGrid.tsx` | `PhotoGrid` + `PhotoGridTile` | `widgets/views/photo_grid.dart`, `widgets/tiles/photo_grid_tile.dart` |
| `MediaList.tsx` | `PhotoListView` | `widgets/views/photo_list_view.dart` |
| `MediaTimeline.tsx` | `PhotoTimelineView` + `TimelineQuickJump` | `widgets/views/photo_timeline_view.dart` |
| `MediaMap.tsx` | `PhotoMapView` + `TripPlaybackController` | `widgets/views/photo_map_view.dart` |
| `FullscreenViewer.tsx` | `FullscreenViewer` + `ZoomController` | `widgets/viewer/fullscreen_viewer.dart` |
| `InfoSidebar.tsx` | `InfoSidebar` + `AnimatedInfoPanel` | `widgets/sidebar/info_sidebar.dart` |
| `AlbumModal.tsx` | `AlbumModal` | `widgets/dialogs/album_modal.dart` |
| `UploadModal.tsx` | *(File picker dialog — native)* | `widgets/dialogs/import_dialog.dart` |
| `KeyboardShortcutsModal.tsx` | `KeyboardShortcutsModal` | `widgets/dialogs/keyboard_shortcuts_modal.dart` |
| `types.ts` | `PhotoFilter`, `PhotoSortOrder`, `PhotoViewMode` | `models/photo_filter.dart` |
| `sampleMedia.ts` | *(Not needed — real data from DB)* | — |

---

## Appendix B — File Inventory

### New Files to Create

```
client/lib/modules/photos/
├── models/
│   └── photo_filter.dart
├── pages/
│   ├── photos_app.dart                    (REWRITE)
│   └── album_detail_page.dart             (NEW)
├── services/
│   ├── photos_repository.dart             (REWRITE)
│   ├── photos_service.dart                (NEW — replaces photos_by_date_service.dart)
│   ├── selection_service.dart             (NEW)
│   ├── view_state_service.dart            (NEW)
│   └── batch_action_service.dart          (NEW)
├── widgets/
│   ├── photo_drawer.dart                  (REWRITE)
│   ├── keyboard_shortcut_handler.dart     (NEW)
│   ├── views/
│   │   ├── photo_grid.dart                (NEW)
│   │   ├── photo_list_view.dart           (NEW)
│   │   ├── photo_timeline_view.dart       (NEW)
│   │   ├── photo_map_view.dart            (NEW)
│   │   ├── timeline_quick_jump.dart       (NEW)
│   │   └── trip_playback_controller.dart  (NEW)
│   ├── tiles/
│   │   ├── photo_grid_tile.dart           (NEW — replaces photo_card.dart)
│   │   └── date_section_header.dart       (NEW)
│   ├── viewer/
│   │   ├── fullscreen_viewer.dart         (NEW)
│   │   └── zoom_controller.dart           (NEW)
│   ├── sidebar/
│   │   ├── info_sidebar.dart              (NEW)
│   │   └── animated_info_panel.dart       (NEW)
│   ├── toolbar/
│   │   ├── photos_toolbar.dart            (NEW)
│   │   └── filter_dropdown.dart           (NEW)
│   ├── drawer/
│   │   ├── drawer_section.dart            (NEW)
│   │   ├── drawer_nav_item.dart           (NEW)
│   │   ├── storage_meter.dart             (NEW)
│   │   └── tag_chip.dart                  (NEW)
│   └── dialogs/
│       ├── album_modal.dart               (NEW)
│       ├── keyboard_shortcuts_modal.dart   (NEW)
│       └── import_dialog.dart             (NEW)
```

### New Test Files to Create

```
client/test/modules/photos/
├── services/
│   ├── photos_repository_test.dart
│   ├── photos_service_test.dart
│   ├── selection_service_test.dart
│   ├── view_state_service_test.dart
│   └── batch_action_service_test.dart
└── widgets/
    ├── photo_grid_test.dart
    ├── photo_grid_tile_test.dart
    ├── fullscreen_viewer_test.dart
    ├── info_sidebar_test.dart
    ├── photo_drawer_test.dart
    ├── photos_toolbar_test.dart
    ├── photo_list_view_test.dart
    ├── photo_timeline_view_test.dart
    ├── photo_map_view_test.dart
    └── album_modal_test.dart

client/integration_test/photos/
├── gallery_navigation_test.dart
├── photo_lifecycle_test.dart
└── search_and_filter_test.dart
```

### Files to Delete

```
client/lib/modules/photos/services/photos_by_date_service.dart   (replaced)
client/lib/modules/photos/widgets/photo_card.dart                (replaced by photo_grid_tile.dart)
```

### Files to Modify

```
client/lib/database_manager.dart          (add migrations for is_favorite, file_tags, album_files)
client/lib/app_router.dart                (add album sub-route)
client/pubspec.yaml                       (add flutter_map, latlong2, flutter_map_marker_cluster)
```

---

## Appendix C — Conventions & Patterns

### RxDart Service Pattern

All new services must follow the existing `RxService<C, R>` pattern:

```dart
class MyService extends RxService<MyCommand, MyResult> {
  // Singleton
  static final MyService _instance = MyService._();
  static MyService get instance => _instance;
  MyService._();

  @override
  Future<MyResult> invoke(MyCommand command) async {
    isLoading.add(true);
    try {
      final result = await _repository.query(command.filter);
      sink.add(result);
      return result;
    } catch (e) {
      sink.addError(e);
      rethrow;
    } finally {
      isLoading.add(false);
    }
  }
}
```

### Widget Subscription Pattern

```dart
class _MyWidgetState extends State<MyWidget> {
  late final StreamSubscription _sub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sub = MyService.instance.sink.listen((data) {
        if (mounted) setState(() => _data = data);
      });
      MyService.instance.invoke(MyCommand());
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}
```

### Naming Conventions

- **Files:** `snake_case.dart`
- **Classes:** `PascalCase`
- **Private members:** `_prefixed`
- **Constants:** `camelCase` (Dart convention)
- **Test files:** `<source_file>_test.dart` mirroring source directory structure

### Theme Usage

```dart
// ✅ Correct — use theme tokens
final color = Theme.of(context).colorScheme.surface;
final textStyle = Theme.of(context).textTheme.bodyMedium;

// ❌ Wrong — never hardcode
final color = Color(0xFF141317);
```

---

## Agent Spawning Guide

Each phase is designed to be independently assignable to an agent. Recommended agent assignments:

| Phase | Recommended Model | Estimated Complexity | Dependencies |
|---|---|---|---|
| **Phase 0** (Data Layer) | Pro | High — DB migrations, repository queries | None (start here) |
| **Phase 1** (Grid View) | Pro | High — core UI, virtualization | Phase 0 |
| **Phase 2** (Lightbox) | Pro | Medium — standalone overlay widget | Phase 0 |
| **Phase 3** (Info Sidebar) | Pro | Medium — metadata display, editing | Phase 0 |
| **Phase 4** (Left Drawer) | Flash | Medium — layout, filter wiring | Phase 0 |
| **Phase 5** (Toolbar) | Flash | Medium — search, filter dropdown | Phase 0 |
| **Phase 6** (List View) | Flash | Low–Medium — tabular layout | Phase 0, Phase 1 (shared tile) |
| **Phase 7** (Timeline) | Pro | Medium — scroll sync, quick jump | Phase 0, Phase 1 (shared tile) |
| **Phase 8** (Map View) | Pro | High — map integration, trip playback | Phase 0 |
| **Phase 9** (Albums) | Flash | Low–Medium — modal, detail page | Phase 0 |
| **Phase 10** (Batch Ops) | Flash | Low — service + toolbar integration | Phase 0, Phase 5 |
| **Phase 11** (Keyboard/A11y) | Flash | Low — shortcuts wrapper, modal | Phase 1, Phase 2 |
| **Phase 12** (Testing) | Pro | High — comprehensive test suite | All phases |
| **Phase 13** (Polish) | Pro | Medium — theme audit, performance | All phases |

**Recommended execution order:**
1. Phase 0 (required first — all others depend on data layer)
2. Phases 1, 2, 3, 4, 5 (can run in parallel after Phase 0)
3. Phases 6, 7, 8, 9, 10, 11 (can run in parallel after their dependencies)
4. Phase 12 (after feature phases complete)
5. Phase 13 (final pass)
