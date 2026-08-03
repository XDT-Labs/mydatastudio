
### From image metadata / tags UI work (2026-08-02)

## Debug the hanging TagsAndLandmarksSection widget test

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

### From OSS documentation pass (2026-08-01)

## Build out the glassmorphism elevation model

`DESIGN.md`'s "Elevation & Depth" section specs a 4-level glass system for the whole
app — panels at 60% opacity / 20px blur, action bars/search at 5% white tint / 12px
blur, `8%` white borders on layered surfaces. In the actual client this is implemented
in exactly one place: the `BackdropFilter`/`ImageFilter.blur` in the Files page's
path/actions bar (`client/lib/modules/files/pages/rx_files_page.dart:1238`). Everywhere
else (nav rail, sidebar, dialogs, other module pages) uses flat Material 3
`surfaceContainer*` fills from `color_schemes.g.dart` with no blur or translucency.

Decision (2026-08-01): build it out to match the spec rather than scale back the doc.
Suggested approach: extract the Files-page glass treatment into a reusable themed
widget (e.g. `GlassPanel`/`GlassSurface`) driven by the `glass`/`glass-elevated`
tokens already defined in `DESIGN.md`'s frontmatter, then apply it to the nav rail,
context sidebar, and dialogs so the elevation model in the doc matches what ships.

### From upgrade handling (2026-07-29)

## Tier 2 auto-update: in-place updates via Sparkle

We now ship a *check-and-notify* updater: on launch `UpdateChecker` asks the GitHub
releases API whether a newer tag exists, and `showUpdateAvailableDialog` sends the user to
the release page to download the DMG by hand. That leaves the actual upgrade — mount,
drag, replace, relaunch — as manual work, and users who dismiss the prompt stay on an old
build indefinitely.

Tier 2 is a real auto-updater: download in the background, verify, swap the `.app`,
relaunch. On macOS that means [Sparkle](https://sparkle-project.org/), via the
[`auto_updater`](https://pub.dev/packages/auto_updater) Flutter plugin (Sparkle on macOS,
WinSparkle on Windows — worth having if the Windows build ever ships).

**Already in place** — the parts most projects get stuck on:
- Developer ID Application signing of the client and every nested binary (`make notarize`).
- Notarization + stapling through `xcrun notarytool` / `stapler`.
- A tagged GitHub release per version with `generate_release_notes: true`
  (`.github/workflows/build_and_release.yml`).
- `make notarize` already produces a `ditto`-zipped `MyDataStudio.zip` for submission —
  today it is deleted after notarization. Sparkle wants exactly that artifact.

**What has to be built:**

1. **Appcast feed.** Sparkle polls an RSS `appcast.xml` rather than the GitHub API. Needs
   one `<item>` per release with version, release-notes URL or embedded CDATA, the zip's
   URL and length, and the EdDSA signature. Publish it from GitHub Pages or a raw file in
   the repo — it has to be a stable URL baked into the app at build time (`SUFeedURL` in
   `Info.plist`).
2. **EdDSA signing keys.** Sparkle 2 verifies updates with its own Ed25519 key, separate
   from Apple codesigning. Run `generate_keys` once, put the public key in `Info.plist` as
   `SUPublicEDKey`, and the private key in GitHub Actions secrets. Each release runs
   `sign_update MyDataStudio.zip` and the resulting signature goes into the appcast item.
   **Losing the private key means no existing install can ever auto-update again** — back it
   up outside CI.
3. **Ship the zip as a release asset.** Stop deleting `MyDataStudio.zip` in the `notarize`
   target and upload it alongside the DMG. Keep the DMG: it stays the first-install path,
   and the Tier 1 notify flow links to it.
4. **CI step to update the appcast.** After the release is published, append the new item
   (version, URL, length, signature, notes) and push the feed. This is the fiddly part —
   the signature must be computed over the exact bytes that get uploaded.
5. **Wire up `auto_updater`** in the client: `setFeedURL`, `setScheduledCheckInterval`,
   and drop the Tier 1 startup check so the two don't both prompt.

**Watch out for:**
- Sparkle needs write access to `/Applications/MyDataStudio.app`. It prompts for
  authorization when the app isn't user-writable; that flow needs testing on a real
  non-admin account, not just the dev machine.
- The aiserver version stamp interacts with this. Sparkle swaps the `.app` and relaunches,
  and the new build re-extracts `aiserver/` on first launch — so an auto-update is followed
  by a ~250 MB extraction with the splash sitting on "Updating AI service...". Acceptable,
  but it means an auto-update is not instant and the UI should say so.
- Prereleases must not reach the stable feed. Either publish two appcasts (stable/beta) or
  filter on the `prerelease` flag when generating.

