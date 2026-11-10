---
status: proposed
adr: none
remaining: [find-trigger, fix, unskip-test]
---

# Debug the hanging TagsAndLandmarksSection widget test

_Moved from `TODO.md` (image metadata / tags UI work, 2026-08-02)._

`client/test/modules/files/widgets/file_details/tags_and_landmarks_section_test.dart`
has one test (`skip: true`) that reliably hung for 2-5+ minutes in this environment
instead of completing, across several rewrites. What's ruled out:

- **Not a compiler/tooling artifact** — confirmed by CPU-time on the
  `frontend_server_aot`/`flutter_tester` processes: sometimes frozen (no CPU growth,
  looked like a stuck compile), sometimes genuinely running for minutes before timing
  out — inconsistent enough that it isn't simply "slow machine."
- **Not multiple `DatabaseManager` init/dispose cycles racing** — `dispose()` calls
  `appDatabase?.close()` without awaiting it (see `database_manager.dart` around line
  392), which looked like a plausible race with a second test's `initializeDatabase()`
  starting immediately after. Collapsing the file to a single `setUp`/`tearDown` cycle
  (one test, all scenarios sequential) did *not* fix it — the hang moved to partway
  through the single remaining test instead of at a cycle boundary.
- **Not the add/delete UI interaction alone** — `pill_list_section_test.dart` exercises
  the identical tap-"+"/enterText/submit/dismiss flow with no database involved and
  passes fast and reliably every time.
- **Not the widget's DB-loading logic alone** — `database_repository_test.dart`'s
  `getFileTags`/`addFileTag`/`deleteFileTag`/`deleteFileLandmark` test passes reliably,
  and `file_browser_integration_test.dart` renders `TagsAndLandmarksSection` inside the
  real `FileDetailsDrawer`/app tree and passes reliably too.

So the actual feature is verified correct through those three tests — this is
specifically about a `testWidgets` test in this one file, combining a real
`DatabaseManager` connection with `tester.runAsync()` (needed because real SQLite I/O
doesn't complete under `pumpAndSettle()`'s fake-clock zone otherwise — see
`settings_test.dart` for the established pattern) and repeated
`tap`/`enterText`/`testTextInput.receiveAction` cycles in one test body. The trimmed
version that ships (load-only, one `runAsync` call, no interaction) passes; re-adding
the add/delete/dedupe steps into the same DB-backed test is what reproduces the hang.

Worth trying in a fresh session with more budget to actually resolve it:
- Bisect by adding back the interaction steps one at a time (tap only; tap + enterText;
  tap + enterText + submit) to find which specific step triggers it.
- Try `tester.pump()` a fixed number of times instead of `pumpAndSettle()` after each
  step, in case `pumpAndSettle`'s "no scheduled frame" polling is itself part of the
  problem when combined with `runAsync`.
- Check whether other `testWidgets` files in this repo call `runAsync` more than once
  in a single test body successfully (`settings_test.dart` does, but doesn't also
  interleave real `TextField` input) — if none do, that combination may be the trigger.
- Consider filing/searching for a Flutter SDK issue on `runAsync` + `TextField` +
  `receiveAction` interaction, since this looked more like a framework-level deadlock
  than application code once the DB and UI logic were independently cleared.
