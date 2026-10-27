---
status: proposed
adr: none
remaining: [t0-schema-and-repository, t1-boards-and-read-only-board, t2-task-editor, t3-moving-tasks, t4-search-filters-completed, t5-custom-columns, t6-archive-links, t7-search-integration, t8-later]
---

# Plan: Tasks app, a kanban board (from the `mockups/kanban-board` prototype)

**Source:** `mockups/kanban-board/`, a Google AI Studio React prototype (React 19, Tailwind,
`motion`, `lucide-react`) running on mock data in `localStorage`. This plan rebuilds it as the
**Tasks** app module in the Flutter client (`client/lib/modules/tasks/`), stored in the SQLite
archive. It's a `group: 'app'` rail entry like Photos and AI Chat, not a collection.

**Decisions (2026-10-26):**

| Question | Decision |
|---|---|
| Rail name | **Tasks** (route `/tasks`, module `modules/tasks/`, tables `task_*`) |
| People / assignees | **Removed.** Single-user app: no team, no assignees, no Acting User, no Team dialog. |
| Boards | **Multiple boards**, one per project or area, from the first UI phase |
| Archive integration order | **1. link tasks to emails, files, photos and other items; 2. unified search.** The rest comes later. |
| Links to deleted items | **Kept**, shown as "no longer in the archive" from `title_snapshot`, so the task keeps its context |
| Semantic search | **Every task gets an embedding** (T7) |
| Completed tasks | **Hidden 7 days after completion**, configurable **per board** in Board settings (7 / 14 / 30 days / never) with a "Show completed" toggle on the board |
| Look and feel | **Inherit the current app theme and shell** (§4). The prototype's Tailwind colours are not ported. |
| Colours | **`TaskColors` maps onto the shared `AccentPalette`** (§4), which Calendar uses too |

Sections: [1](#1-prototype-inventory) inventories every element and behaviour of the prototype,
[2](#2-what-changes-in-the-port) says what we drop or change, [3](#3-data-model) is the
schema, [4](#4-theme-and-styling-inherited-from-the-app) the theming, [5](#5-flutter-architecture)
the code layout, and [6](#6-phases) the phases.

## 1. Prototype inventory

### 1.1 Screen layout (`App.tsx`)

| Band | Height | Contents |
|---|---|---|
| **Header** | 64 | Logo "T" + "TaskFlow Board"; **search field** ("Search active tasks...", magnifier icon); **Acting User** selector (member first names + initials avatar). |
| **Toolbar** | 56 | Left: "Workspace: Board Overview", an "Internal" badge, **progress stats** ("Progress: 3/4 completed \| 75% rate"). Right: **Assignee filter**, **Priority filter**, **Clear filters** (only while a filter is set), **Team** button, **Add Task** (primary). |
| **Board** | flex | Three columns side by side (min 280 px each), gap 24. The board scrolls horizontally when narrow; each column scrolls vertically. |
| **Footer** | 32 | "System Online", "N Active Board Members", a drag hint, "Version 2.4.0-stable", **Reset Board**. |

### 1.2 Column (`Column.tsx`)

- Fixed columns: `todo` "To-Do" (slate dot), `in_progress` "In Progress" (blue), `done` "Done"
  (emerald), each with its own header tint.
- **Header:** dot, title, **count** of the *filtered* tasks, and a **"+"** that opens the task
  dialog in create mode with this column preselected.
- **Empty state:** a dashed box, "No tasks here yet", and a "Create a task" link (same as "+").
- **Drop target:** drag-over highlights the column (blue border + shadow); a drop moves the
  dragged task here.

### 1.3 Task card (`TaskCard.tsx`)

1. **Top row:** a check icon (Done only); a **priority badge** (LOW green / MEDIUM amber / HIGH
   red); a **short id** (`TK-…`, mono); **Edit** and **Delete** icons, shown on hover (always on
   small screens).
2. **Title** (one line) and **description** (two lines, or "No description provided."). Clicking
   either opens the editor.
3. **Subtask progress** (if any): "Subtasks", "2/3", a thin bar.
4. **Tags** as `#tag` chips (if any).
5. **Footer row:** a **due-date chip** (rose when overdue; "No due date" otherwise), a **← / →**
   pair that moves the card one column (disabled at the ends), and the **assignee avatar**.

Status styling: In Progress cards get a 4 px blue left border. Done cards are at 70% opacity with
the title struck through. **Overdue** = due date before now and not Done. Cards fade/slide in and
out over 200 ms, and `layoutId` animates moves.

### 1.4 Task dialog (`TaskModal.tsx`)

Centred (max 512 wide, 90% high, body scrolls) over a blurred 70% black backdrop; fade + scale
0.95 → 1 + 16 px slide, 200 ms. Title "Create New Team Task" / "Edit Task Details"; close X.

| Field | Control | Rules |
|---|---|---|
| Task Title * | text | **Required**: "Task title is required" (red border + icon), cleared by typing. Trimmed. |
| Description | textarea, 3 rows | Trimmed. |
| Priority | select | Green (Low) / Orange (Medium) / Red (High); default **Medium**. |
| Board Stage | select | The three columns; default = the column it was opened from (toolbar **Add Task** = To-Do). |
| Assignee | select | Unassigned + members. *(Dropped in the port.)* |
| Due Date | date | Optional, `YYYY-MM-DD`. |
| Subtasks Checklist | text + **Add** | **Enter** or Add appends (trimmed, empty ignored). Rows: checkbox toggle (struck-through when done) and delete. List max 140 high. Empty: "No checklist checkpoints yet." |
| Tags & Categorization | text + **Add** | **Enter** or Add appends; leading `#` stripped; duplicates ignored (case-sensitive). Chips with ×. Empty: "No tags associated yet." |

Footer: **Cancel** and **Create Task / Save Changes**. **All edits are a local draft** until
Save: Cancel, X and a backdrop click discard it without asking.

### 1.5 Team dialog (`TeamModal.tsx`): dropped

Member list with delete (unassigns their tasks), an add form (name, role, 8 avatar colours). Not
ported (single-user app).

### 1.6 Board behaviour

- **Search** (title, description, any tag; case-insensitive substring) AND **Assignee** AND
  **Priority** filters. Counts and stats use the filtered set.
- **Progress:** `done / total` and `round(done / total × 100)%`.
- **Move:** drag and drop or ← / →. Dropping on the same column does nothing. There is **no
  reordering within a column** (creation order).
- **Delete:** a `confirm()` naming the task, then a hard delete.
- **Persistence:** whole arrays as JSON in `localStorage`. A `kanban_activities` key is cleared
  on reset but never written: an activity log was planned and never built.

### 1.7 Prototype bugs not to copy

- Saving is skipped when the array is empty, so **deleting the last task brings the mock data
  back** on reload.
- **Overdue** compares `new Date('YYYY-MM-DD')` (UTC midnight) with now, so in US time zones a
  task shows overdue the evening before it's due. Compare **local calendar dates**.
- The short id is a slice of a random id, not a stable number.
- Tag duplicates are case-sensitive (`UI` vs `ui`).

## 2. What changes in the port

**Dropped:**
- Demo chrome: the logo and title (the rail provides them), the "Internal" badge, the footer
  and Reset Board.
- Everything to do with people: Acting User, Team dialog, the Assignee field, filter and avatar.
- The mock data. The first open creates one empty board, "My Tasks", with three columns.

**Added:**
- **Boards:** a list of boards in the Tasks drawer (create, rename, archive, delete) and Board
  settings.
- **Order within a column**, with drag-to-reorder; dropping between two cards inserts there.
- **Stable task numbers** per board (`TK-12`), with the prefix set in Board settings.
- **`completed_at`**, set on entering the done column and cleared on leaving it. It drives the
  7-day auto-hide and, later, timeline and calendar views.
- **"Discard changes?"** when closing a changed draft (the prototype silently loses work on a
  stray backdrop click).
- **Keyboard support** (the footer promised "action key triggers"; see [T3](#t3-moving-tasks)).
- **Links to archive items** ([T6](#t6-archive-links)), the reason a task board belongs in My
  Data Studio.

**Renamed:** "Create New Team Task" → "New task", "Board Stage" → "Column".

## 3. Data model

Raw DDL appended to `AppDatabase.schemaDDL` (no code generation; see `CLAUDE.md`), with plain
Dart models in `models/tables/` and hand-written `fromMap`/`toMap`. Conventions match the
existing tables: `TEXT` UUID keys, `INTEGER` epoch-millisecond timestamps, and foreign keys
with explicit `ON DELETE` (resqlite enables `PRAGMA foreign_keys` on every connection).

```sql
CREATE TABLE IF NOT EXISTS task_boards (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT,
  icon INTEGER,                                -- Material icon code point, shown in the drawer
  task_prefix TEXT NOT NULL DEFAULT 'TK',      -- shown as TK-12
  next_task_number INTEGER NOT NULL DEFAULT 1,
  hide_completed_after_days INTEGER DEFAULT 7, -- NULL = never hide
  position REAL NOT NULL DEFAULT 0,            -- order in the drawer
  archived_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS task_columns (
  id TEXT PRIMARY KEY,
  board_id TEXT NOT NULL,
  name TEXT NOT NULL,
  accent TEXT NOT NULL DEFAULT 'neutral',      -- TaskColors key: neutral | primary | success | warning | danger | info
  position REAL NOT NULL,
  is_done INTEGER NOT NULL DEFAULT 0,          -- tasks here count as completed
  created_at INTEGER NOT NULL,
  FOREIGN KEY (board_id) REFERENCES task_boards(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_columns_board ON task_columns(board_id, position);

CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  board_id TEXT NOT NULL,
  column_id TEXT NOT NULL,
  number INTEGER NOT NULL,
  title TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  priority TEXT NOT NULL DEFAULT 'medium' CHECK (priority IN ('low', 'medium', 'high')),
  due_date TEXT,                               -- 'YYYY-MM-DD', a local calendar date, no time zone
  position REAL NOT NULL,                      -- order within the column
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER,
  UNIQUE (board_id, number),
  FOREIGN KEY (board_id) REFERENCES task_boards(id) ON DELETE CASCADE,
  FOREIGN KEY (column_id) REFERENCES task_columns(id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_tasks_column ON tasks(column_id, position);
CREATE INDEX IF NOT EXISTS idx_tasks_due ON tasks(due_date) WHERE due_date IS NOT NULL;

CREATE TABLE IF NOT EXISTS task_subtasks (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  title TEXT NOT NULL,
  completed INTEGER NOT NULL DEFAULT 0,
  position REAL NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_subtasks_task ON task_subtasks(task_id, position);

CREATE TABLE IF NOT EXISTS task_tags (
  task_id TEXT NOT NULL,
  tag TEXT NOT NULL COLLATE NOCASE,            -- case-insensitive uniqueness; keeps the first spelling
  PRIMARY KEY (task_id, tag),
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_tags_tag ON task_tags(tag);

-- T6: links from a task to anything in the archive
CREATE TABLE IF NOT EXISTS task_links (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  item_type TEXT NOT NULL CHECK (item_type IN ('email', 'file', 'photo', 'folder', 'social_post', 'url')),
  item_id TEXT,                                -- emails.id / files.id / folders.id / social_posts.id; NULL for 'url'
  url TEXT,                                    -- for 'url' links
  title_snapshot TEXT NOT NULL,                -- subject / file name at link time, shown if the item is gone
  position REAL NOT NULL,
  created_at INTEGER NOT NULL,
  FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_task_links_task ON task_links(task_id, position);
CREATE INDEX IF NOT EXISTS idx_task_links_item ON task_links(item_type, item_id);
```

**Design notes:**
- **Columns are rows, not an enum.** The prototype's `status` becomes `column_id`, and "Done" is
  `is_done = 1`. New boards get To-Do / In Progress / Done, so custom columns (T5) need no
  migration. Overdue, strike-through, progress and auto-hide all read `is_done`, never a column
  name.
- **`position REAL`** is a fractional index (insert between 1.0 and 2.0 → 1.5), so a move
  writes one row. Below a 1e-6 gap the repository renumbers that column in one transaction.
- **Tags are a child table**, so "all tasks tagged X" and autocomplete are indexed queries.
  They're Tasks-only. Whether they merge with `file_tags` is a later question.
- **`task_links` is polymorphic** (`item_type` + `item_id`), with no foreign key, because it
  points into several tables. So:
  - deleting an email or file does **not** cascade, and the delete paths leave links alone
    (decided 2026-10-26). The link renders from `title_snapshot` in a "no longer in the archive"
    state, so the task keeps its context. The user can remove it from the editor;
  - `photo` is a `files` row shown with the photo viewer; it's kept as its own type so the chip
    opens the right viewer.
- **Auto-hide** is a read-time rule, not a write: a task is hidden when its column `is_done`
  and `completed_at < now − hide_completed_after_days`. Nothing is deleted or moved.
- **Deleting a column** with tasks is refused by `RESTRICT`; the UI moves its tasks first (T5).
- **`next_task_number`** is read and bumped in the same transaction as the insert.

**Repository** (`repositories/tasks_repository.dart`): the only code that touches these tables.
It all runs on the main isolate; no scanner or isolate writes are involved.
- Boards: `ensureDefaultBoard()`, `listBoards({includeArchived})`, `createBoard(name)` (with the
  three default columns), `updateBoard`, `archiveBoard`, `deleteBoard`.
- `loadBoard(boardId, {includeHiddenCompleted})` → board, columns, tasks with subtasks, tags and
  link counts, plus `hiddenCompletedCount` per done column. That's a fixed number of queries;
  child rows come from batched `IN (…)` queries, not per task.
- `createTask(draft)` / `updateTask(draft)`: writes the task and **replaces** its subtasks, tags
  and links in one transaction, since the dialog saves a whole draft.
- `moveTask(taskId, toColumnId, {beforeTaskId, afterTaskId})`: computes the position, sets or
  clears `completed_at`, and renumbers if needed.
- `deleteTask`, `setSubtaskCompleted`, `linksForItem(itemType, itemId)` (for "Linked tasks" on an
  email or file, T6).
- Writes return the updated rows, so the controller updates state without reloading the board.

## 4. Theme and styling: inherited from the app

The Tasks module adds **no colours, fonts or shapes of its own** beyond one small semantic
extension. Everything comes from the theme built in `family_dam_app.dart` (`_buildTheme`) from
`color_schemes.g.dart`, and from the shell's existing widgets.

**What exists today, and how Tasks uses it:**

| App today | Tasks uses it for |
|---|---|
| **Dark only:** `themeMode: ThemeMode.dark`; the dark `ColorScheme` in `color_schemes.g.dart` (obsidian surfaces, lavender `primary` `#e8ddff`) | Every colour via `Theme.of(context).colorScheme`. No hex values in `modules/tasks/`. Light must still look right, because the light scheme exists. |
| **System font:** `.AppleSystemUIFont` + fallbacks, with the sizes in `_buildTheme`'s `textTheme` | `textTheme.titleSmall` (card titles), `bodySmall` (descriptions), `labelSmall` (chips, counts), `titleMedium` (column headers), `titleLarge` (board name). `DESIGN.md` §Typography documents this (updated 2026-10-26). No `fontFamily` in `modules/tasks/`; `TK-n` numbers use SF Mono. |
| **Surface scale** `surface` → `surfaceContainerLowest…Highest` | Board background `surface`; columns `surfaceContainerLow`; cards via `cardTheme`; card hover and drag-over `surfaceContainerHigh`; inputs and the search pill `surfaceContainerHigh`. |
| **`cardTheme`:** `surfaceContainerLowest`, radius 8, 1 px `outlineVariant` border, elevation 1 | Task cards are plain `Card`s. The drag feedback raises elevation and tints the border `primary`. |
| **"The No-Line Rule":** `dividerColor` transparent, `dataTableTheme` with zero dividers | **No divider lines.** The prototype's `border-t` card footer, `divide-y` subtask list and toolbar divider become spacing and tonal steps (a `surfaceContainer` strip, gaps). |
| **`checkboxTheme`:** `primary` fill when checked, `outlineVariant` side | Subtask checkboxes, as-is. |
| **Shell:** `RoutePage` + `NavigationWrapper(body:, drawer:)`; rail entries from the `apps` table | `/tasks` → `NavigationWrapper(body: TasksBoardPage, drawer: TasksDrawer)`, exactly like `/photos`. |
| **Drawers:** `DrawerSection` / `DrawerNavItem` (`modules/photos/widgets/drawer/`), 240 px wide | **`TasksDrawer`** lists boards with these same widgets: the Boards section, an Archived section, and "New board". If a second module now needs them, move the two widgets to `lib/widgets/drawer/` in their own small change, not inside a Tasks phase. |
| **`DESIGN.md` component rules:** pill search with no border and a 2 px `primary` focus ring; icon-only toolbar buttons with a circular hover; micro-caps labels; panel radius 16 | The search field, the toolbar icon buttons (Show completed, Board settings), field labels in the editor (the prototype's uppercase tracked labels already match), and the column container radius. |
| **Dialogs:** `showDialog` / `AlertDialog` with the default M3 dialog theme, as in `email_drawer.dart` / `file_drawer.dart` | Delete confirms and "Discard changes?" use `AlertDialog`. The task editor is a `Dialog` on the same theme (max 560 wide); no custom blur backdrop unless the glass work below has landed. |
| **Glass:** `DESIGN.md`'s target, built out by [glassmorphism-elevation.md](glassmorphism-elevation.md) (`ready`, not built) | **Use its widgets if they exist when Tasks is built; otherwise use the flat `surfaceContainer*` scale** like every other module today. Tasks doesn't build its own glass. |

**The one addition: a `TaskColors` `ThemeExtension`**, registered in `_buildTheme` with a dark
and a light value. The scheme has no green or amber roles, and `tertiary` is reserved for
file/folder metaphors (`DESIGN.md`), so priorities and column accents need named colours:

| Key | Used for | Dark value (derived from) |
|---|---|---|
| `danger` | High priority, overdue chip | `colorScheme.error` / `errorContainer` |
| `warning` | Medium priority | `AccentPalette.amber` |
| `success` | Low priority, done check, Done column accent | `AccentPalette.green` |
| `info` | column accent | `AccentPalette.blue` |
| `primary` / `neutral` | column accents | `colorScheme.primary`, `onSurfaceVariant` |

Each key is a `(foreground, container)` pair, with container badges in the M3 style
(`…Container` fill, `on…Container` text). Badge text must pass **WCAG AA**; a widget test checks
the contrast ratios.

**`TaskColors` is a thin semantic layer over the shared `AccentPalette`** (decided 2026-10-26).
`AccentPalette` is the 12-hue `ThemeExtension` in `lib/theme/accent_palette.dart`, defined in
[app-calendar.md](app-calendar.md) §4, and Calendar uses it for calendar colours. **Whichever
app is built first creates it.** `TaskColors` only gives hues task meanings, so the two apps'
greens and ambers are always the same colours, and no amber or green is tuned twice.

**Motion** follows the app: modest, 150–200 ms, `Curves.easeOutCubic`. No `motion`-style
spring layouts.

## 5. Flutter architecture

```text
client/lib/modules/tasks/
  pages/
    tasks_board_page.dart          # /tasks and /tasks/:boardId
  widgets/
    tasks_drawer.dart              # boards list (DrawerSection / DrawerNavItem)
    board_toolbar.dart             # board name, search, priority filter, clear, stats, show-completed, settings, New task
    board_settings_dialog.dart     # name, icon, prefix, hide-completed-after, archive/delete
    task_column.dart               # header, count, +, list, empty state, hidden-completed footer, DragTarget
    task_card.dart                 # every visual state in §1.3 minus the avatar, plus a link count
    task_card_drag.dart            # Draggable wrapper, feedback, ghost
    task_editor_dialog.dart        # §1.4 minus Assignee, plus Links (T6)
    priority_badge.dart, due_date_chip.dart, tag_chip.dart, subtask_progress.dart, task_link_chip.dart
  services/
    tasks_board_controller.dart    # board state, filters, optimistic moves
    task_filter.dart               # pure: (tasks, query, priority, showCompleted, now) -> visible tasks
    task_draft.dart                # mutable copy edited by the dialog; isDirty
    fractional_position.dart       # pure: between(a, b), needsRenumber
  theme/
    task_colors.dart               # the ThemeExtension in §4
```

- **Route and rail:** `GoRoute('/tasks')` and `/tasks/:boardId` in `app_router.dart`. A seed
  row in `_loadInitialData`: `slug: 'tasks'`, `name: 'Tasks'`, `group: 'app'`, the
  `Icons.view_kanban` code point, `route: '/tasks'`. `/tasks` opens the last-used board
  (in-memory, falling back to the first one).
- **State:** `TasksBoardController` holds the loaded board and filters. It's exposed through the
  same pattern as the newest module code (`RxService`/`BehaviorSubject` or a `ChangeNotifier`;
  **match the photos rewrite**). Moves are **optimistic**: update state, write, and roll back
  with a snackbar if the write throws.
- **Filtering** is a pure function over the loaded tasks (hundreds per board, not millions).
  Search is debounced 150 ms.
- **Drag and drop:** hand-rolled on Flutter's `Draggable` / `DragTarget` rather than a package,
  so it follows the theme and our position maths. (`appflowy_board` is the fallback; verify
  it's maintained.)
  - `Draggable<String>` (task id), not `LongPressDraggable`, so a mouse drag starts at once.
    `feedback` is the card at its own width, raised (elevation, `primary` border, 2° tilt);
    `childWhenDragging` is a same-height ghost in `surfaceContainerHigh`.
  - Each column is a `DragTarget`. On hover it shows a `surfaceContainerHigh` fill and `primary`
    outline (the prototype's highlight) plus an **insertion bar** (2 px `primary`) between the two
    cards nearest the pointer, found from card `GlobalKey` rects.
  - Dropping in the slot the card came from writes nothing.
  - **Auto-scroll** a column near its top or bottom 48 px, and the board near its left or right
    edge. **Esc** cancels a drag.
- **Hover actions:** `MouseRegion` shows Edit/Delete (the prototype's `group-hover`). They're
  always visible below 768 px wide.
- **Dates:** due dates are parsed and compared as local `DateTime(y, m, d)`, never through UTC.
  The chip shows `MMM d` (plus the year if it isn't this year) via `intl`. Dates are picked with
  `showDatePicker`, plus Clear.

## 6. Phases

Each phase ends with a working, tested slice. Tests come first for the repository and the pure
services. Widget tests cover each phase's UI. `flutter analyze` must be clean and the full
`flutter test` suite must pass.

### T0. Schema and repository

- [ ] The DDL from §3 (including `task_links`, so T6 needs no migration) and its indexes.
- [ ] Models: `TaskBoard`, `TaskColumn`, `Task` (with `subtasks`, `tags`, `links`),
      `TaskSubtask`, `TaskLink`; a `TaskPriority` enum; `fromMap` / `toMap`.
- [ ] `fractional_position.dart`.
- [ ] `TasksRepository` per §3.
- [ ] Tests (real resqlite, like `test/repositories/`):
  - round trips for every table;
  - `number` increments per board and survives deletes;
  - a move sets/clears `completed_at`, and a reorder writes one row;
  - renumbering kicks in below the threshold;
  - deleting a task cascades to subtasks, tags and links, and deleting a board cascades to
    everything on it;
  - deleting a column that still has tasks fails;
  - `UI` / `ui` collapse to one tag;
  - **deleting the last task leaves zero tasks** (the prototype bug);
  - `hiddenCompletedCount` respects `hide_completed_after_days`, including `NULL` = never.

**Done when** the tests pass and `database_manager_test` still passes on an existing archive
(the new tables appear on open; nothing else changes).

### T1. Boards and the read-only board

- [ ] The rail seed row and `/tasks` + `/tasks/:boardId` routes; `ensureDefaultBoard()` on
      first open.
- [ ] **`TasksDrawer`:** boards (selected state, task counts), an Archived section (collapsed),
      **New board** (name prompt → three default columns), and a per-board menu: Rename,
      Settings, Archive / Unarchive, Delete (confirm with the task count).
- [ ] **`AccentPalette`** (unless Calendar created it first) and **`TaskColors`** on top of it,
      both registered in `_buildTheme`, with the contrast test.
- [ ] Toolbar shell: board name; other controls inert until their phase.
- [ ] `TaskColumn`: accent dot, name, count, "+" (inert), scrolling list, empty state.
- [ ] `TaskCard`, every state:
  - priority badge and `TK-n`;
  - done: check, strike-through, reduced emphasis (`onSurfaceVariant`, not opacity);
  - the column accent on the left edge for non-first, non-done columns (generalising "In
    Progress");
  - subtask progress, tags;
  - the due chip with **local-date** overdue;
  - the link count (when > 0).
- [ ] Widget tests: each card state; overdue is false on the due date itself and true the day
      after; done tasks are never overdue; empty-state rendering; switching boards in the
      drawer changes the route and the columns.

**Done when** several boards can be created and switched between, and a test-seeded board
looks like the prototype in the app's own theme.

### T2. Task editor

- [ ] `TaskDraft`: a copy of a task or a blank one for a column; `isDirty`; `validate()`.
- [ ] `TaskEditorDialog`, with every §1.4 field except Assignee:
  - title, required, with the inline error cleared on typing;
  - description, priority, **column** (this board's columns), and the due date with Clear;
  - subtasks: Enter/Add, toggle, delete, a scrolling list, the empty text;
  - tags: Enter/Add, `#` stripped, case-insensitive de-dupe, chips with ×, the empty text, and
    **autocomplete from the board's existing tags**;
  - Cancel / Create task / Save changes.
- [ ] Draft semantics: nothing is written until Save. Esc, X, Cancel and a barrier tap close the
      dialog, asking **"Discard changes?"** only if the draft is dirty. **Cmd/Ctrl+Enter** saves.
- [ ] Wire up the toolbar **New task** (first column), the column "+" and the empty-state link
      (that column), and card click / **Edit**.
- [ ] **Delete** from the card: an `AlertDialog` naming the task, then removal with a fade.
- [ ] Tests: validation; draft isolation (toggle a subtask, cancel → unchanged); the dirty guard;
      create lands at the bottom of the chosen column with the next number; edit replaces
      subtasks and tags; delete.

**Done when** tasks can be created, edited and deleted with every field, and survive a restart.

### T3. Moving tasks

- [ ] **← / →** buttons (disabled at the ends), moving to the end of the neighbouring column.
- [ ] Drag and drop between columns, per §5: feedback, ghost, column highlight, drop.
- [ ] **Reorder within a column** with the insertion bar; no write when dropped in place.
- [ ] Auto-scroll of columns and board; Esc cancels.
- [ ] Optimistic update with rollback + snackbar on a failed write.
- [ ] **Keyboard:**
  - cards are focusable (Tab, and the arrow keys move focus);
  - **Enter** opens the focused card, **Delete/Backspace** asks to delete it;
  - **Cmd/Ctrl+←/→** moves it to the next column, **Cmd/Ctrl+↑/↓** reorders it;
  - `Semantics` announces moves ("Moved to Done").
- [ ] Tests: the position maths for top, middle and bottom drops; a widget drag from To-Do to
      Done (it lands, counts change, `completed_at` is set); the arrow buttons; the keyboard
      moves; a simulated write failure rolls back.

**Done when** moving and reordering feel instant, persist, and work by mouse, buttons and
keyboard.

### T4. Search, filter and completed tasks

- [ ] A search pill (title, description, tags; case-insensitive; debounced). **Cmd/Ctrl+F** or
      **/** focuses it; Esc clears it.
- [ ] The Priority filter (All / Low / Medium / High). Clear filters appears only while a filter
      is set.
- [ ] Progress: "3/4 completed · 75%" over the visible tasks.
- [ ] **Auto-hide completed:** done columns hide tasks completed more than
      `hide_completed_after_days` ago. The column footer reads "12 older completed tasks hidden ·
      Show". The toolbar **Show completed** toggle (icon button) reveals them on this board for
      the session.
- [ ] **Board settings dialog:** name, icon, task prefix, and **Hide completed tasks after: 7 /
      14 / 30 days / Never** (default 7 for new boards). Opened from the toolbar and the drawer
      menu.
- [ ] With a filter active, **dragging still works**: positions are computed against the
      neighbouring *visible* cards.
- [ ] Filters are remembered per board for the session (in memory).
- [ ] Tests: the `task_filter` truth table (search × priority × completed-age × show-completed);
      the boundary (exactly 7 days); `Never`; stats rounding.

**Done when** the toolbar behaves like the prototype's (minus assignees), and old completed
work stays out of the way without being lost.

### T5. Custom columns

- [ ] A column menu (⋯ in the header): Rename, Accent (the `TaskColors` keys), **Mark as done
      column**, Move left/right, Add column to the right, Delete. Deleting a non-empty column asks
      where to move its tasks.
- [ ] Optional: drag a column by its header to reorder it (the menu already covers this).
- [ ] Changing which column is "done" recomputes `completed_at` for the tasks it affects.
- [ ] Tests: add, rename, reorder, delete-with-move, done-column change.

**Done when** each board can have its own workflow.

### T6. Archive links (integration 1)

- [ ] **From a task:** a **Links** section in the editor. "Add link" opens a picker that searches
      the archive (emails by subject or sender, files and photos by name), or takes a URL. Links
      show as chips (an icon per type plus `title_snapshot`); a chip opens the item in its own
      module (email detail, file details, the photo viewer) or the URL in the browser.
- [ ] **From an item:** an **"Add to task…"** action in the email detail, the file details panel
      and the photo viewer, to pick a board + task or create a new task with the item linked and
      its title prefilled. Those views also show a **Linked tasks** list
      (`linksForItem`).
- [ ] Cards show a link icon and count; the card tooltip lists the links.
- [ ] A link to a deleted item stays, rendered from `title_snapshot` as "no longer in the
      archive" (disabled open, still removable). The lookup that resolves chips batches by
      `item_type`, and a missing row means dangling.
- [ ] Tests: link round trips; `linksForItem`; "Add to task…" with a new task; the dangling-link
      rendering.

**Done when** an email, a file or a photo can be turned into a task or attached to one, and you
can get from either side to the other.

### T7. Unified search (integration 2)

- [ ] Tasks become a result type in [unified-search.md](unified-search.md): title, description,
      tags and subtask titles. Keyword matching first, through the same full-text path the other
      types use.
- [ ] **Semantic search: one embedding per task** (decided 2026-10-26), in a new table
      that mirrors `emails_embeddings`:

      ```sql
      CREATE TABLE IF NOT EXISTS tasks_embeddings (
        task_id TEXT NOT NULL,
        chunk_index INTEGER NOT NULL DEFAULT 0,   -- 0 only; kept for symmetry with emails/files
        embeddinggemma2_embedding BLOB,
        model_version TEXT,
        PRIMARY KEY (task_id, chunk_index),
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
      );
      ```

      - The embedded text is the title, description, tags, subtask titles, the board and
        column names, and the linked items' `title_snapshot`s, so "the task about the
        insurance email" finds it.
      - Embeddings are made by the shared text-row embedding isolate (the social foundation's)
        through `POST /util/embedding`, and written back via the main isolate like the other
        embedding isolates. If the social foundation hasn't landed, T7 builds that isolate.
      - Saving a task clears its row (`model_version` mismatch or a missing row = stale), and the
        isolate re-embeds it in the background. It pauses while scanners sync, like the others.
      - Search runs the vector query next to `files_embeddings` / `emails_embeddings` and merges
        the results through unified search's existing ranking.
- [ ] A result opens the board with the task's editor.
- [ ] Tests: indexing on create, update and delete; an edit makes the embedding stale and it is
      re-embedded; deleting a task cascades its embedding; a search hit opens the right task.

**Done when** global search finds tasks next to emails, files and photos.

### T8. Later (not scheduled)

- **LLM tools:** `list_tasks`, `create_task` and `move_task` in the tool registry
  ([ADR 0001](../adr/0001-llm-tool-registry.md)), e.g. "what's overdue?" or "make a task from
  this email". Writes need confirmation.
- **Calendar:** due dates and `completed_at` on the calendar planner app (from
  `mockups/calendar-planner`, planned separately).
- **Activity log:** the prototype's unbuilt `kanban_activities` (created, moved, completed), as a
  history list in the editor.
- **An app-wide default** for "hide completed after", if per-board settings prove tedious. It
  would go in **Settings → Tasks**, a new `SettingsDrawer` entry next to AI Chat.

## Open questions

None at the moment. All the questions so far are settled in the decisions table at the top.
