---
status: proposed
adr: none
remaining: [l0-index-and-schema, l1-map-and-timeline, l2-lanes, l3-playback, l4-social-posts, l5-stories, l6-gps-tracks, l7-flights-and-email, l8-later]
---

# Plan: Timeline app, play back your life (from the `mockups/map-timeline-viewer` prototype)

**Source:** `mockups/map-timeline-viewer/`, a Google AI Studio React prototype ("LifeMap
Playback Viewer": React 19, Tailwind, `motion`, `@vis.gl/react-google-maps`, an Express server
calling Gemini). It plays back three hand-written sample "stories" on a Google Map, with seven
fixed lanes underneath. This plan rebuilds it as the **Timeline** app module in the Flutter
client (`client/lib/modules/timeline/`), drawing on the user's real archive.

**What it's for:** playing back your life. The archive's dated items sit in **lanes** at the
bottom, like the tracks in Adobe Premiere, all on one long, shared time ruler. Items with a
location are shown on the **map** above. Pressing **Play** moves through time:

> a hike (its GPX track drawing itself on the map) → a few photos from the summit → the social
> post about the spot → the flight home (from the confirmation email)

The camera flies to each item, pauses on it, and moves on, speeding through the empty
stretches in between.

**Decisions (2026-10-27):**

| Question | Decision |
|---|---|
| Rail name | **Timeline** (route `/timeline`, module `modules/timeline/`, tables `timeline_*`), `group: 'app'` |
| Where the data comes from | **Drawn from the existing archive, not copied.** A small **`timeline_items` index** has one row per dated item (photo, post, track, flight, email…) with its time, place and lane fields, kept current automatically (§3.2). More timeline sources come later. |
| Source order | **1. photos and videos; 2. social posts; 3. GPS tracks; 4. flights from confirmation emails** (and email lanes). **Calendar events later.** |
| Google Maps Timeline / Location History | **Much later.** Remembered as a future source (L8), not planned now. The prototype's **Road Trips** lane waits for it. |
| Empty stretches | **Played faster: 5× the current speed for now**, to be tuned by trying it (§5.2). |
| Playback | **Pause on each item**, **draw tracks and flights** along their real timestamps, and **move the camera**, giving the map time to animate to the next place **before** pausing there. |
| Stories | **Saved, named time ranges** ("Alps 2024"), made from a selection on the timeline. Automatic trip detection is later. |
| Lanes | **User-defined.** Adding a lane opens a dialog to pick a **data type, one or more collections, and filters**. **The defaults depend on the type** (§3.3): **one lane for all GPX files**, **one for Strava**, **one per email collection**, one per social platform, one for photos and videos. |
| Map | `flutter_map` with the **CARTO dark tiles the Photos map already uses**: no API key, and the same look across the app. The prototype's Google Maps and its mock map are not ported. |
| Look and feel | **Inherit the current app theme and shell** (§4). Lane colours come from the shared **`AccentPalette`** ([app-calendar.md](app-calendar.md) §4). |

Sections: [1](#1-prototype-inventory) inventories the prototype,
[2](#2-what-changes-in-the-port) says what we drop or change, [3](#3-data-model) is the schema,
[4](#4-theme-and-styling-inherited-from-the-app) the theming,
[5](#5-playback) the playback engine, [6](#6-flutter-architecture) the code layout, and
[7](#7-phases) the phases.

## 1. Prototype inventory

### 1.1 Screen layout (`App.tsx`)

| Band | Size | Contents |
|---|---|---|
| **Header** | ~72 high | Logo, "LifeMap Playback Viewer" / "Visual Timeline GPS Analyzer", and **STORY:** chips for the three sample stories (West Coast Odyssey, Alpine Summit Escape, Brooklyn Creator Walk). Picking one replaces all events. |
| **Map** | 60% | Google Map (or the mock map), with a status badge top-left ("Google Maps Live Connected" / "Visual Mock Map Engine Active"). |
| **Transport bar** | ~72 high | Previous event, **Play / Pause** (green / rose), Next event, Reset to start; a **speed** select. |
| **Timeline** | the rest | A toolbar (title, **PLAYHEAD:** date and time to the second, zoom out / "Scale: n%" / zoom in), lane headers on the left (192 wide), and the scrolling lanes. |

Decorative blurred colour blobs sit behind everything. **State:** the events, the selected
event, and playback (`isPlaying`, `speed`, `currentTimestamp`, `windowSizeHours` = 12).
Nothing is saved.

### 1.2 Data shape (`types.ts`, `samples.ts`)

- Every event has `id`, `source`, `title`, `timestamp` (one ISO instant), optional
  `locationName`, and a required `coordinate`.
- Per source: **twitter** (text, username, likes, retweets); **photos** (photoUrl, caption,
  cameraInfo, image/video); **calendar** (description, durationMins, organizer); **facebook**
  (text, mood, likes); **gpx** (path, distanceMiles, elevationGainFeet, avgPace); **flights**
  (flight number, airline, departure and arrival codes, path, speed, altitude); **roadtrip**
  (start and end city, path, vehicle, durationHours).
- **Paths have no timestamps**, so a track can't be replayed in real time.

### 1.3 Timeline (`TimelineContainer.tsx`)

- **Range:** from the first to the last event, padded 8% each side.
- **Zoom:** levels 1–10, each 1.8× the last; "Scale: 10%" … "100%".
- **Ruler:** ticks about every 180 px, rounded to 15 min, 30 min, 1 h, 3 h, 6 h, 12 h, 1 day, 3
  days or 7 days. Labels are times ("3:00 PM", with the date at midnight) or dates ("Jun 3");
  each tick has a dashed grid line down through the lanes.
- **Seven fixed lanes**, each with an icon, label and item count: Flight Records, Road Trips,
  GPX Hikes, Calendar Events, Photos & Videos, Twitter Tweets, Facebook Posts.
- **Items:**
  - instant items (tweets, photos, Facebook posts) are 24 px circles with the lane icon;
  - duration items are bars, with a **fixed length per type** (flights 2.5 h, hikes 3 h, road
    trips `durationHours` or 4 h, calendar `durationMins`, others 45 min), showing the title and
    "4.2mi", "SFO✈️JFK" or "DRIVE";
  - items in the active window are full colour, others faded; the selected one has a rose
    border;
  - **hover** shows a balloon (title, time, text or caption); **click** selects, and clicking
    again deselects.
- **Playhead:** a red line with a handle. **Dragging it or the ruler scrubs** (window-level
  mouse tracking); a click on the ruler jumps.
- **Auto-scroll:** while the playhead is outside the middle 50% of the view, the view
  smooth-scrolls to centre it.
- **Active-range shading** between the first and last active event.

### 1.4 Playback (`App.tsx`, `PlaybackControls.tsx`)

- A `requestAnimationFrame` loop advances the playhead by the frame's real time × a rate:
  Realtime = 5 min of life per second, 5× = 25 min, 15× = 2 h (the default), 50× = 8 h, 100× =
  24 h.
- **At the end it loops** back to the start.
- **Active events** are those in the **12 hours before the playhead**.
- **Previous / Next event** jump the playhead to the previous or next event's time, wrapping
  around. **Reset** goes to the start and pauses.
- A **ticker message** describing the event nearest the playhead ("✈️ Flying: Flight …",
  "🥾 Hiking Track: …") is computed but **never rendered**.

### 1.5 Map (`MapContainer.tsx`)

- A dark custom style; greedy gestures; zoom and scale controls only.
- **Every event is a marker**: a coloured circle with the source icon. Active ones are full
  size and colour, inactive ones grey at 75%, and the selected one is 1.3× with a rose ring and
  a ping.
- **Paths** (GPX, flights, road trips) are geodesic polylines: active 5 px at 90%, inactive 2 px
  at 25%.
- **Camera:** on every change of the active set (that is, every frame while playing), it fits
  the active events and their paths (max zoom 13), or pans to the selected event at zoom 11.
- **Info window** on the selected event: source, title, date and time, and type-specific
  details (tweet text, post text and mood, a photo placeholder and caption, hike distance,
  ascent and pace, flight and route, drive route and vehicle).
- **The mock map** (no API key) plots everything on an equirectangular canvas.

### 1.6 Server (`server.ts`)

- `POST /api/generate-timeline` asks Gemini to **invent** a geocoded timeline from a prompt
  (with made-up paths). The UI never calls it.

### 1.7 Prototype bugs and gaps not to copy

- **Constant-rate playback:** a night with nothing in it takes as long as a busy afternoon.
- **The content is never shown.** Photos are a 📸 emoji or a camera icon; the ticker isn't
  rendered; nothing says what is happening now.
- **Durations are invented per type** (every hike is 3 h, every flight 2.5 h) instead of coming
  from the data, and paths have no timestamps.
- **The map refits on every frame** while playing, so it fights the user and jitters.
- **Every event is a marker at once**, which doesn't scale past a few dozen.
- The 12-hour window can't be changed.
- Zoom only covers the story's range; there's no way to see years.
- Lanes are fixed, can't be hidden or reordered, and items in one lane overlap each other.
- Times use `toLocaleString` with no time zone, so a photo's local time and a flight's UTC time
  mix silently.
- Playback loops forever at the end.
- The Gemini endpoint fabricates data.

## 2. What changes in the port

**Dropped:** the logo and subtitle, the background blobs, the Google Maps key and the mock
map, the map status badge, the sample stories, the Gemini timeline generator, the Road Trips
lane (until Location History), and the fixed Twitter/Facebook lanes (they become social-platform
lanes).

**Changed:**
- **Real data from the archive** through `timeline_items`, with **real durations**: a track
  runs from its first to its last point, a flight from departure to arrival.
- **One ruler from decades to minutes.** Zooming is continuous (scroll with ⌘, pinch, or the
  zoom slider), and zoomed out, each lane shows a **density strip** (how many items per day,
  week or month) instead of individual items (§3.4).
- **Lanes are user-defined** (§3.3): add, edit, hide, collapse, reorder and delete. **Overlapping
  items stack** into extra rows within a lane, and instant items that would overlap at the
  current zoom merge into a **cluster** with a count.
- **Smart playback** (§5): the camera flies to each item, then pauses on it while a **Now
  playing** panel shows the photo, video, post, track or flight. Tracks and flights draw
  themselves along their real timestamps. Empty stretches play at 5× speed. Playback **stops at
  the end** of the range or story (Loop is a toggle).
- **The map only refits on demand.** During playback it follows the beats (§5.3); when the user
  pans or zooms, **Follow** turns off until they press it again.
- **Markers cluster** at low zoom (as the Photos map does), and only items in the active window
  (adjustable: 1 h, 6 h, 12 h, 1 day, 3 days or 1 week) are drawn full colour.
- **Stories** are saved time ranges with in and out points, set with `I` and `O` as in Premiere
  (§3.1, L5).
- **Times are shown in the zone where the item happened** when it's known (a photo in Tokyo
  shows Tokyo time), with the playhead's own readout in the device's zone (§3.5).
- **Keyboard:** Space play/pause; **J / K / L** reverse, pause, forward (Premiere's shuttle,
  pressing again speeds up); ← / → previous and next item; `I` / `O` in and out; `F` toggles
  Follow; ⌘+ / ⌘− zoom; `\` zooms to fit the range. Registered in the app's shortcuts sheet.

## 3. Data model

Raw DDL appended to `AppDatabase.schemaDDL` (no code generation; see `CLAUDE.md`), with plain
Dart models in `models/tables/` and hand-written `fromMap`/`toMap`. Conventions match the
existing tables: `TEXT` UUID keys, `INTEGER` epoch-millisecond timestamps, and explicit
`ON DELETE`.

### 3.1 Tables

```sql
-- The index: one row per dated archive item. Not a copy: it points at the item's own row.
CREATE TABLE IF NOT EXISTS timeline_items (
  item_type TEXT NOT NULL,               -- 'photo' | 'video' | 'social_post' | 'track' | 'flight' | 'email' (later 'calendar_event')
  item_id TEXT NOT NULL,                 -- files.id / social_posts.id / tracks.id / flights.id / emails.id
  collection_id TEXT,                    -- for per-collection lanes
  subtype TEXT,                          -- social platform, track source ('file' | 'strava'), activity, …
  start_utc INTEGER NOT NULL,            -- epoch ms, UTC
  end_utc INTEGER NOT NULL,              -- = start_utc for instant items
  time_zone TEXT,                        -- IANA zone where it happened, when known (§3.5)
  lat REAL, lng REAL,                    -- the item's point (a track's start), NULL if no location
  min_lat REAL, min_lng REAL, max_lat REAL, max_lng REAL,  -- tracks and flights: their extent
  title TEXT,                            -- tooltip and Now playing heading
  PRIMARY KEY (item_type, item_id)
);
CREATE INDEX IF NOT EXISTS idx_timeline_items_type_time ON timeline_items(item_type, start_utc);
CREATE INDEX IF NOT EXISTS idx_timeline_items_collection_time ON timeline_items(collection_id, start_utc);
CREATE INDEX IF NOT EXISTS idx_timeline_items_time ON timeline_items(start_utc);

CREATE TABLE IF NOT EXISTS timeline_lanes (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,                    -- "Photos & videos", "Strava", "Gmail · mike@…"
  item_type TEXT NOT NULL,               -- what the lane shows (one type per lane)
  collection_ids TEXT,                   -- JSON array; NULL = every collection of that type
  filters TEXT,                          -- JSON, per type (§3.3)
  color TEXT NOT NULL,                   -- AccentPalette key
  icon INTEGER,                          -- Material icon code point
  position REAL NOT NULL,
  is_hidden INTEGER NOT NULL DEFAULT 0,
  is_collapsed INTEGER NOT NULL DEFAULT 0,
  is_default INTEGER NOT NULL DEFAULT 0, -- created by the rules in §3.3, so re-running them doesn't duplicate it
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS timeline_stories (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  cover_file_id TEXT,
  hidden_lane_ids TEXT,                  -- JSON: lanes hidden while this story plays
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (cover_file_id) REFERENCES files(id) ON DELETE SET NULL
);
```

`tracks` (L6) and `flights` / `airports` (L7) are created in their phases, in §7.

### 3.2 Keeping the index current

- **SQLite triggers** keep `timeline_items` in step with the source tables, so it stays right
  however a row is written (scanner relay, user action, backfill), and the main-isolate write
  rule is unchanged: a trigger runs inside the same statement.
  - `files`: `AFTER INSERT` / `UPDATE` / `DELETE`. A file is indexed when it's an image or video
    (`content_type`) with a taken time, and not `is_deleted`, `is_hidden`, `is_user_deleted` or
    `is_inline`. Email attachments are indexed with `subtype = 'email_attachment'`, so the
    photos lane can include or exclude them (excluded by default).
  - `social_posts`, `tracks`, `flights`, `emails`: the same, added in their phases.
- **A one-time backfill** (`INSERT … SELECT`) fills the index for existing rows when the table
  is created, and again for each new source type.
- **Tests** check that every write path leaves the index right, because a trigger bug would
  silently hide items.

### 3.3 Lanes, filters and the default lanes

**Adding a lane** opens a dialog: **Type** (Photos & videos, Social posts, GPS tracks, Flights,
Email; Calendar later) → **Collections** (one or more of that type, or All) → **Filters** (per
type, below) → **Name** and **Colour**. The lane header's menu has Edit, Hide, Collapse and
Delete; dragging a header reorders lanes.

| Type | Filters |
|---|---|
| Photos & videos | photos / videos / both; favourites only; with a location only; albums; include email attachments; a search query |
| Social posts | platform; kind (post, reply, story, …); with a location only; a search query |
| GPS tracks | source (files / Strava); activity (hike, run, ride, …); minimum distance |
| Flights | airline; airport |
| Email | folder or label; from / to; has attachments; a search query |

- **Search queries use the global search syntax** (`from:`, `near:`, words), parsed by the
  existing `SearchFilters`. A lane with a query is resolved to a set of item ids once and
  cached, and refreshed when its source collections change.
- **Default lanes** are created on first open, and when a new collection or source appears, by
  these rules (each lane `is_default = 1`, so the rules never duplicate one):

  | Data | Default lanes |
  |---|---|
  | Photos and videos | **one** lane, every photo collection |
  | Social posts | **one per platform** (X, Facebook, Instagram, …) |
  | GPS tracks | **one** lane for **all GPX/FIT/TCX files**, whichever collection they're in, plus **one for Strava** |
  | Flights | **one** lane |
  | Email | **one per email collection** |

  The user can delete or change any default lane; deleting one stops the rule from bringing it
  back.

### 3.4 Reading the index at any zoom

- **Zoomed in** (fewer than about 2,000 items in view per lane): `SELECT … WHERE item_type = ?
  AND start_utc < :to AND end_utc > :from` (plus the lane's collections and filters), laid out
  into rows by a pure `LaneLayout`.
- **Zoomed out:** a **density strip**: `SELECT start_utc / :bucket AS b, COUNT(*) … GROUP BY b`,
  with the bucket matched to the zoom (hour, day, week, month), drawn as a bar's height or a
  heat strip in the lane's colour.
- The **map** asks for items with a location in the visible map bounds and the active window,
  capped and clustered.
- **Target:** under 50 ms per lane query on an archive of 500,000 items, measured in L1 with a
  generated test archive.

### 3.5 Time rules

1. Every instant is **UTC epoch milliseconds**, the same rule as the Calendar plan.
2. **Photo taken time** is the hard case. EXIF `DateTimeOriginal` is a local time with no zone
   unless `OffsetTimeOriginal` is present.
   - **Verify** which column holds the taken time today. `files` has only `date_created` /
     `date_last_modified`, and it's not yet clear whether scanners put EXIF time there.
   - If none does, L0 adds **`files.taken_utc`** and **`files.taken_tz`**, filled by the
     scanners and backfilled from EXIF.
   - The zone comes from, in order: the offset tag, the GPS UTC timestamp, the time zone of
     the photo's location (**verify** whether the bundled gazetteer has a time-zone column),
     and finally the device's zone, flagged as a guess.
3. **Flights** keep departure and arrival in UTC, converted from the airport's local times with
   the airport's zone (L7).
4. **Display:** items show their own local time when `time_zone` is known; the ruler and
   playhead readout use the device's zone, with the item's zone shown when it differs ("2:10 PM
   in Tokyo").

## 4. Theme and styling: inherited from the app

The Timeline adds **no colours, fonts or shapes of its own.** Everything comes from
`_buildTheme` in `family_dam_app.dart`, `color_schemes.g.dart`, `DESIGN.md`, the shell's widgets
and the shared `AccentPalette`, as in the Tasks, Calendar and Photo Editor plans.

| App today | Timeline uses it for |
|---|---|
| **Dark only:** the dark `ColorScheme` | Everything via `Theme.of(context).colorScheme`; no hex values in `modules/timeline/`. The prototype's rose accents become `primary`. |
| **System font** | `labelSmall` with tabular figures for ruler labels and the playhead readout (the prototype's mono becomes tabular figures, not a mono font); `labelMedium` lane names; `bodySmall` tooltips; `titleMedium` the Now playing heading. |
| **Surface scale** | Lanes `surfaceContainerLow`, alternating rows `surfaceContainerLowest`; lane headers and the ruler `surfaceContainer`; the transport bar `surfaceContainerHigh`. |
| **"The No-Line Rule"** | Lanes are separated by tonal steps, not borders. **Ruler grid lines are the same exception as the calendar grid** (hairlines in `outlineVariant` at low opacity, [app-calendar.md](app-calendar.md) §4), drawn by the one timeline `CustomPainter`. |
| **`AccentPalette`** (shared, `lib/theme/`) | **Lane colours.** Each lane has a palette key; items use `container` fills with an `accent` edge, and map markers and tracks use `accent`. Defaults: photos `pink`, tracks `green`, Strava `orange`, flights `purple`, email `blue`, each social platform its own hue. |
| **Playhead and selection** | The playhead is a 2 px `primary` line with a handle (`primary` fill). The selected item gets a 2 px `primary` outline. Items outside the active window drop to 40% alpha and `onSurfaceVariant` text. |
| **Shell:** `RoutePage` + `NavigationWrapper` | `/timeline` uses `NavigationWrapper` **without a drawer**; stories live in a toolbar menu. |
| **`DESIGN.md` components** | Transport buttons are icon buttons with a circular hover; **Play** is a `FilledButton` icon; the speed and window pickers are `MenuAnchor`s; the Add lane dialog is a `Dialog` with M3 form fields. |
| **Map** | `flutter_map`, the **same CARTO `dark_all` tiles and attribution** as `photo_map_view.dart`, so the maps match. |
| **Glass** ([glassmorphism-elevation.md](glassmorphism-elevation.md)) | The Now playing panel, tooltips and the floating transport bar over the map, if the glass widgets exist by then; otherwise `surfaceContainerHigh` at 90%. |

**Motion:** camera moves ease with `Curves.easeInOutCubic` (§5.3); UI transitions 150–200 ms
`Curves.easeOutCubic`, as in the other plans.

## 5. Playback

### 5.1 Beats

Playback isn't a clock running at a fixed rate. A pure **`PlaybackScheduler`** turns the items
in the range (visible lanes only) into a sequence of **beats**, and a ticker plays them:

| Beat | When | What happens | Length |
|---|---|---|---|
| **Run** | time between items | the playhead moves at the chosen speed | real gap ÷ speed |
| **Fast run** | an **empty stretch** (no item starts or is in progress for longer than a threshold, default 2 h) | the same, **5× faster** (decision; tuned by trying it) | gap ÷ (speed × 5) |
| **Fly** | before each item with a location, when it's somewhere else | the camera animates to the item; **the playhead holds** until the camera arrives | 0.8–2.5 s, by distance |
| **Dwell** | at an instant item | the playhead holds; the item is highlighted on the map and shown in **Now playing** | photo 3 s, video up to 8 s (muted clip), post 4 s; settings |
| **Draw** | a track or flight | the playhead advances through the item's own duration while the line **draws itself point by point** along its timestamps, and the camera follows the moving head | the item's duration ÷ a draw speed, clamped to 4–20 s |

- **Bursts:** photos taken within 10 minutes and 200 m of each other become **one dwell**, a
  short slideshow (1.5 s each, up to 8), so 40 summit photos don't take two minutes. The
  thresholds are settings.
- **Overlaps:** an item that starts during a draw (a photo taken mid-hike) is shown in Now
  playing **without stopping the draw**, with a pin popping up on the track.
- **Speeds** keep the prototype's choices (5 min, 25 min, 2 h, 8 h, 24 h of life per second);
  the default is 2 h. J / L step through them.
- **Previous / Next** jump to the previous or next **beat's** item (not wrapping).
  **Reverse** (J) plays runs backwards and skips dwells and draws.
- **Scrubbing** pauses playback; releasing the playhead resumes if it was playing.
- **The end** stops playback at the end of the story or range (Loop is a toggle).

### 5.2 Tuning

The numbers above (gap threshold, the 5× gap speed, dwell times, fly times, burst limits) are
first guesses. They live in one `PlaybackTuning` object, are exposed in **Settings ›
Timeline**, and get tuned in L3 by playing real archives. The user said usability testing will
decide what's best.

### 5.3 Camera

- **Fly:** an animated `MapController` move (centre and zoom together) along an arc: zoom out
  to see both places, pan, zoom in. Short hops just pan. The zoom at arrival fits the item (a
  street for a photo, the whole track for a hike, both airports for a flight). The animated
  move is built on `flutter_map`'s controller with an `AnimationController`, or with the
  `flutter_map_animations` package if it's maintained (**verify**).
- **Follow** is on during playback. Panning or zooming the map by hand turns it off, with a
  "Follow" chip to turn it back on. No refit on every frame (the prototype's jitter).
- **Items without a location** (most email, some posts) dwell without moving the camera.

### 5.4 Now playing panel

A panel on the right of the map (collapsible, 360 wide) showing the current beat's item:
- **photo:** the image (the thumbnail first, then the full image), date, place and camera;
- **video:** a muted clip;
- **social post:** the shared `SocialPostCard` from the social foundation;
- **track:** name, distance, climb, duration and an **elevation profile** with a moving
  marker;
- **flight:** airline, flight number, the airports, and departure and arrival times in local
  time;
- **email:** sender, subject and the first lines.

Clicking it **opens the item** in its own module (Photos viewer, email, …) and pauses playback.
When paused, the panel shows the selected item instead.

## 6. Flutter architecture

```text
client/lib/modules/timeline/
  pages/
    timeline_page.dart             # /timeline, /timeline/story/:id, /timeline?at=<utc>
  widgets/
    timeline_toolbar.dart          # story menu, range readout, window picker, zoom-to-fit, Add lane
    timeline_map.dart              # flutter_map: tiles, clusters, tracks, flight arcs, active window, Follow chip
    now_playing_panel.dart         # §5.4
    transport_bar.dart             # prev, play/pause, next, start, speed, loop
    timeline_view.dart             # ruler + lane headers + lanes, scrolling and zoom gestures
    timeline_painter.dart          # CustomPainter: ruler, grid, density strips, items, clusters, in/out range, playhead
    lane_header.dart               # name, colour, count, menu, drag handle
    add_lane_dialog.dart           # type -> collections -> filters -> name/colour
    item_tooltip.dart
    story_dialog.dart
  services/
    timeline_controller.dart       # range, zoom, playhead, selection, lanes, loaded windows
    timeline_scale.dart            # pure: time <-> px, tick intervals and labels from decades to minutes
    lane_layout.dart               # pure: items -> rows, clusters at the current zoom
    lane_query.dart                # lane (type, collections, filters) -> SQL + cached search-query ids
    default_lanes.dart             # §3.3 rules
    playback_scheduler.dart        # pure: items + tuning -> beats (§5.1)
    playback_ticker.dart           # plays beats; drives the playhead, camera and panel
    camera_director.dart           # fly / follow / fit (§5.3)
    playback_tuning.dart
client/lib/repositories/timeline_repository.dart
client/lib/models/tables/timeline_item.dart, timeline_lane.dart, timeline_story.dart
```

- **Route and rail:** a seed row in `_loadInitialData`: `slug: 'timeline'`, `name: 'Timeline'`,
  `group: 'app'`, the `Icons.timeline` code point, `route: '/timeline'`. `/timeline?at=<utc>`
  opens at a moment, so other modules can link in ("Show on timeline" in the photo viewer and
  in search results).
- **State:** `TimelineController`, using the same state pattern as the other app plans. Lane
  data loads per visible window, plus half a screen either side, and reloads when the index
  changes in the visible range.
- **The timeline is one `CustomPainter`**, not a widget per item, so tens of thousands of items
  scroll smoothly. Hit-testing (hover, click) uses `LaneLayout`'s rectangles. Lane headers are
  ordinary widgets in a `ReorderableListView` beside it, scrolled in step.
- **Gestures:** drag on empty lanes pans; drag the playhead or the ruler to scrub; ⌘-scroll or
  pinch zooms around the pointer; shift-drag on the ruler selects a range (for a story).
- **Auto-scroll** keeps the playhead in the middle half of the view while playing (the
  prototype's behaviour), but not while the user is dragging.
- **Layout:** map and timeline are split by a draggable divider (default 60/40, remembered);
  the Now playing panel sits on the map's right.

## 7. Phases

Each phase ends with a working, tested slice. Tests come first for the repository and the pure
services. Widget tests cover each phase's UI. `flutter analyze` must be clean and the full
`flutter test` suite must pass.

### L0. Index and schema

- [ ] **Photo taken time first** (§3.5): find where it's stored. If nowhere, add
      `files.taken_utc` / `files.taken_tz`, fill them in the scanners, and backfill from EXIF.
- [ ] The DDL from §3.1, and the `files` triggers and backfill (§3.2).
- [ ] Models; `TimelineRepository`: items in a range for a lane, density buckets, items in map
      bounds, lanes and stories CRUD.
- [ ] `default_lanes.dart` with the photos rule.
- [ ] Tests:
  - every `files` write keeps the index right: insert, a date change, hide, delete,
    user-delete, an inline email image (not indexed), a non-image (not indexed);
  - the backfill indexes an existing archive;
  - half-open range queries; density buckets add up to the item count;
  - taken-time zone resolution in each fallback order;
  - the default rules don't duplicate a lane, and a deleted default stays deleted;
  - **performance:** lane and density queries on a generated 500,000-item archive, under 50 ms.

**Done when** the index holds every dated photo and video in an existing archive, and stays
right as files change.

### L1. Map and timeline (read-only)

- [ ] The rail seed row, route, and the split layout.
- [ ] `timeline_scale.dart`: continuous zoom from decades to minutes, with tick intervals from
      10 years down to 1 minute and locale-aware labels (`intl`).
- [ ] `TimelinePainter`: the ruler, grid, density strips when zoomed out, items and stacked rows
      when zoomed in, clusters, the playhead.
- [ ] Scrubbing, panning, zooming around the pointer, zoom-to-fit, tooltips, click to select.
- [ ] `TimelineMap`: clustered markers for items with a location, the active window (picker:
      1 h … 1 week), and selection synced both ways with the timeline.
- [ ] The Now playing panel for photos and videos (showing the selection).
- [ ] "Show on timeline" in the photo viewer (`/timeline?at=…`).
- [ ] Tests: tick intervals and labels at every zoom; `LaneLayout` stacking and clustering;
      the scale round-trips time ↔ px; selecting on the map selects on the timeline and the
      reverse.

**Done when** a whole photo archive can be browsed on the timeline from decades down to
minutes, with the photos on the map.

### L2. Lanes

- [ ] Lane headers: name, colour, count in view, the menu (Edit, Hide, Collapse, Delete), drag to
      reorder.
- [ ] `AddLaneDialog` and `lane_query.dart` (§3.3), with the photo filters and search queries.
- [ ] Tests: each photo filter changes the lane's items; a search-query lane uses
      `SearchFilters` and refreshes when its collection changes; reordering and hiding persist;
      a lane over two collections shows both.

**Done when** the user can build their own lanes from collections and filters.

### L3. Playback

- [ ] `PlaybackScheduler` (§5.1) and `PlaybackTuning` (§5.2), with **Settings › Timeline**.
- [ ] `PlaybackTicker` and `CameraDirector`: run, fast run (5×), fly, dwell, photo bursts; Follow.
- [ ] The transport bar: previous, play/pause, next, back to start, speed, loop; J / K / L, Space,
      ← / →.
- [ ] Now playing during playback; clicking opens the item and pauses.
- [ ] Tests (pure, with a fake clock):
  - a 10-hour empty night plays 5× faster than the same gap with an item in it;
  - **the camera arrives before the dwell starts** (the user's rule);
  - a burst of 40 photos is one dwell of at most 8;
  - hidden lanes produce no beats;
  - reverse skips dwells;
  - playback stops at the end unless Loop is on;
  - scrubbing pauses and resumes.

**Done when** pressing Play on a trip's photos flies from place to place, pauses on each set of
photos, and skips quickly through the nights.

### L4. Social posts

Depends on the social foundation (`social_posts`, `SocialPostCard`) from the social plans.

- [ ] `social_posts` triggers and backfill; one default lane per platform.
- [ ] Social filters (platform, kind, with location, search query).
- [ ] Posts in Now playing (`SocialPostCard`), and dwell beats for posts.
- [ ] Tests: posts indexed on import and removed on delete; a post without a location dwells
      without moving the camera; per-platform default lanes appear when a platform is imported.

**Done when** posts play back alongside photos.

### L5. Stories

- [ ] In and out points (`I` / `O`, or shift-drag on the ruler), shown as a shaded range.
- [ ] **Save as story** (name, description, cover photo, lanes to hide); the story menu in the
      toolbar; edit, delete; `/timeline/story/:id`.
- [ ] A story bounds the timeline and playback to its range and hides its hidden lanes.
- [ ] Tests: a story round-trips; playing a story stops at its out point; hidden lanes come back
      when leaving the story.

**Done when** "Alps 2024" can be saved and played back from the story menu.

### L6. GPS tracks

**One shared `tracks` table** for every source, used by this plan and by
[social-strava-archive.md](social-strava-archive.md) (which originally proposed its own
`activity_tracks`):

```sql
CREATE TABLE IF NOT EXISTS tracks (
  id TEXT PRIMARY KEY,
  collection_id TEXT,
  source TEXT NOT NULL CHECK (source IN ('file', 'strava')),  -- later 'location_history'
  file_id TEXT,                          -- the GPX/FIT/TCX file, when there is one
  social_post_id TEXT,                   -- Strava: the activity's post
  name TEXT,
  activity TEXT,                         -- hike | run | ride | walk | ski | … (from the file or Strava)
  start_utc INTEGER NOT NULL,
  end_utc INTEGER NOT NULL,
  distance_m REAL, elevation_gain_m REAL, moving_time_s INTEGER,
  min_lat REAL, min_lng REAL, max_lat REAL, max_lng REAL,
  points BLOB NOT NULL,                  -- packed (lat, lng, elevation, time offset) per point
  overview TEXT NOT NULL,                -- encoded polyline simplified for display (Douglas–Peucker)
  created_at INTEGER NOT NULL,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE,
  FOREIGN KEY (social_post_id) REFERENCES social_posts(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_tracks_time ON tracks(start_utc);
```

- [ ] A **`TrackIndexer`** that runs after file scans: GPX and TCX (XML, Dart, with the `xml`
      package already in the app) and FIT through the aiserver's `/util/parse/fit` (from the
      Strava plan). It fills `tracks`, with the distance, climb and moving time computed.
      Multi-segment files become one track per segment when the gap is over an hour.
- [ ] `tracks` triggers and backfill; default lanes **"GPS tracks" (all files)** and **"Strava"**.
- [ ] Map: tracks drawn from `overview`, with more detail from `points` at high zoom; the
      **draw beat** animating along the timestamps, with the elevation profile in Now playing.
- [ ] Photos taken during a track's time and near its line show as pins on it (the Strava plan's
      "During: Morning ride").
- [ ] Update [social-strava-archive.md](social-strava-archive.md) to write Strava routes into
      `tracks` (done in this plan's commit).
- [ ] Tests: parsing fixture GPX/TCX/FIT files (with and without times; multiple segments);
      distance and climb within 1% of a reference; a track without timestamps draws at a fixed
      speed instead; packed points round-trip; deleting the file deletes the track and its
      index row.

**Done when** a folder of GPX files plays back as hikes drawing themselves on the map, with the
photos along the way.

### L7. Flights from email, and email lanes

```sql
CREATE TABLE IF NOT EXISTS airports (       -- bundled OurAirports data (public domain), loaded like the gazetteer
  iata TEXT PRIMARY KEY,
  icao TEXT, name TEXT NOT NULL, city TEXT, country TEXT,
  lat REAL NOT NULL, lng REAL NOT NULL, time_zone TEXT
);

CREATE TABLE IF NOT EXISTS flights (
  id TEXT PRIMARY KEY,
  airline TEXT, flight_number TEXT NOT NULL,
  departure_iata TEXT NOT NULL, arrival_iata TEXT NOT NULL,
  departure_utc INTEGER NOT NULL, arrival_utc INTEGER NOT NULL,
  confirmation_code TEXT,
  status TEXT NOT NULL DEFAULT 'booked' CHECK (status IN ('booked', 'changed', 'cancelled')),
  source TEXT NOT NULL CHECK (source IN ('schema_org', 'llm')),   -- later 'tripit'
  email_id TEXT,                         -- the newest email that described it
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (email_id) REFERENCES emails(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_flights_identity ON flights(flight_number, departure_iata, departure_utc);
```

- [ ] **Extraction, cheapest first:**
  1. **schema.org markup**: `FlightReservation` JSON-LD or microdata in the stored HTML body,
     which most airlines and travel agents include (it's what Gmail's travel cards read).
     Parsed in Dart.
  2. **The local LLM** for emails without markup that look like flight emails (sender domains of
     airlines and agents, and subjects like "itinerary", "confirmation", "boarding pass"): a
     structured-output request through `/v1/chat/completions` that returns the same fields.
     Results with missing airports or times are dropped, not guessed.
  3. TripIt's own itinerary emails go through the same two steps. Its calendar feed arrives
     later through the Calendar app.
- [ ] **Merging:** booking, change, check-in and cancellation emails for the same flight update
      one row (the identity index); a cancellation sets `cancelled`, and cancelled flights are
      hidden by default.
- [ ] Airport local times → UTC with the airport's zone (§3.5).
- [ ] An indexer over existing and newly scanned email; `flights` triggers and backfill; the
      **Flights** default lane.
- [ ] Map: **great-circle arcs** between the airports, drawn by the draw beat with a plane icon
      at the head; Now playing shows the flight card.
- [ ] **Email lanes:** `emails` triggers and backfill (`item_type = 'email'`, no location); **one
      default lane per email collection**; the email filters (§3.3); density strips keep
      large mailboxes readable.
- [ ] Tests: fixture emails from several airlines (JSON-LD, microdata, no markup); a change email
      updates the same flight; a cancellation hides it; local → UTC across a date line; the LLM
      path drops incomplete results; email lanes per collection appear as defaults.

**Done when** the flight home from a confirmation email draws its arc on the map in the right
place on the timeline.

### L8. Later (not scheduled)

- **Calendar events** as a lane, once the Calendar app ([app-calendar.md](app-calendar.md))
  exists: `calendar_events` triggers, one default lane per calendar collection, duration bars.
- **Google Maps Timeline / Location History** (decision: much later): the Takeout or on-device
  export, for **where-was-I** points, **drives** (bringing back the Road Trips lane), walks and
  visits.
- **Automatic trips:** detect time away from home and offer them as stories.
- **More timeline options** (the user's note on decision 1): more sources and lane types.
- **Export a story as a video** (map, tracks and photos rendered to MP4).
- **Narration:** the local LLM writes a short caption per day of a story.
- **Offline map tiles** for archives viewed without a connection.
- **Search and LLM tools:** "what was I doing on 3 June 2019?" answered from `timeline_items`,
  through the tool registry ([ADR 0001](../adr/0001-llm-tool-registry.md)).

## Open questions

None at the moment. All the questions so far are settled in the decisions table at the top.
