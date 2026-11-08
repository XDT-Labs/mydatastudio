# Roadmap

Every feature in flight or planned, with its status and where its details live. Status values
and how to keep this file current are explained in [README.md](README.md). The order the social,
email and file sources are built in, by wave, with dependencies and checklists, is in
[RELEASE-PLAN.md](RELEASE-PLAN.md).

**Wave** is the [release plan](RELEASE-PLAN.md) wave an item is built in (`0`–`11`), `deferred`
when it's waiting on a gate, `any` for work that can start at any time, or `—` for work
outside the release plan. An item that ships in
parts lists each wave (`1, 4`). Within each section, rows are ordered by wave.

## In progress

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Unified search | `in-progress` | — | [unified-search.md](plans/unified-search.md) | — | Phases 1–6 and §13 autocomplete built. Phase 7 (document extraction and chunking, §18) is designed, its spike passed, and `aiserver/src/aichat/document_extractor.py` has started it. |

## Core app

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Releases cut from version tags | `in-progress` | any | [core-ci-linux-build.md](plans/core-ci-linux-build.md) | — | `verify-tag` job written 2026-11-03: every platform takes its version from it; production tags must be on main, and pre-release tags work on any branch (2026-11-07). First full pass on GitHub 2026-11-07 (`v1.2.3-beta.3`: macOS and both Linux builds published to one pre-release). The main-only rule hasn't been tried with a plain tag yet. |
| Glassmorphism elevation model | `ready` | — | [glassmorphism-elevation.md](plans/glassmorphism-elevation.md) | — | Decision made 2026-08-01 to build out `DESIGN.md`'s spec. |
| Tier 2 auto-update (Sparkle) | `proposed` | — | [sparkle-auto-update.md](plans/sparkle-auto-update.md) | — | Probably needs an ADR (EdDSA key custody, appcast hosting). |
| Fix hanging `TagsAndLandmarksSection` widget test | `proposed` | — | [fix-tags-landmarks-widget-test.md](plans/fix-tags-landmarks-widget-test.md) | — | Test is `skip: true`; investigation notes in the plan. |
| Windows desktop build in GitHub Actions | `proposed` | any | [core-ci-windows-build.md](plans/core-ci-windows-build.md) | — | No `client/windows/` yet; Windows commented out in `build_python.yml`. Replace `webview_flutter` for email HTML, Recycle Bin (unparks the row below), aiserver CPU/GPU builds, MSIX or Inno installer, code signing. |
| Linux desktop build in GitHub Actions | `in-progress` | any (before 7) | [core-ci-linux-build.md](plans/core-ci-linux-build.md) | — | Runner scaffolded and plugin audit done 2026-11-03: builds on Ubuntu 22.04 arm64 and starts under Xvfb; `flutter_angle`'s Linux plugin is skipped at build time and the STL preview is off on Linux. Linux email view done (`flutter_widget_from_html_core` plus Open in browser; `<style>` rules, floats and flex don't render, and it hasn't been tried on real mail). PDF preview moved to `pdfrx` on every platform. Freedesktop Trash done. aiserver CPU build done (document extraction needs Ubuntu 24.04+). CI job, x86_64 + arm64 matrix, AppImage, tar.gz and Xvfb smoke test written and checked on five clean arm64 distros. Passed its first tag run on GitHub 2026-11-07 (`v1.2.3-beta.3`, x64 and arm64). Left: trying it on a real Ubuntu desktop. Prerequisite for the NAS container. |
| Synology NAS container (Linux desktop in the browser) | `proposed` | 7 | [core-nas-docker.md](plans/core-nas-docker.md) | — | The Linux bundle on a maintained GUI-in-browser base image (jlesage or LinuxServer); NAS shares bind-mounted read-only. Web auth + TLS, in-container browser for OAuth, the AI workload (local CPU vs remote aiserver), Synology `@eaDir`/`#recycle` excludes, multi-arch GHCR image. |

## Shared foundations

Prerequisites for the Social, Email and Files sections, plus the external approvals that gate
deferred work.

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Social: shared foundation | `proposed` | 0 | [social-x-sync.md](plans/social-x-sync.md) §Shared social foundation | 0002 (to write) | **ADR 0002** (`social_posts`, embeddings, `imported_exports`, `social_sync_state`, `files.social_post_id`); `archive` + `csv` packages; `ScannerManager` periodic trigger; shared setup panel + file picker + Downloads watcher; `SocialPostCard` + feed; search integration; text-row embedding isolate. Prerequisite for every Social row. |
| Email: shared IMAP engine | `proposed` | 0 | [email-imap-engine.md](plans/email-imap-engine.md) | — | Merge the ~90%-identical Yahoo/Outlook isolates into one `ImapScanner` + provider registry; UID/CONDSTORE incremental sync; one setup flow with autodetect. Prerequisite for the Email rows. |
| Files: shared foundation | `in-progress` | 0 | [files-sources-foundation.md](plans/files-sources-foundation.md) | — | Merged in #40: `CloudFileScanner`, change-cursor sync, content policy, PKCE, content hash, the add-source catalog, sync-folder detection with online-only checks. Left: `providerHint`, "download for indexing". |
| Google restricted-scope verification (Gmail + Drive) | `proposed` | 0 (spike), deferred | [email-gmail.md](plans/email-gmail.md) §A, [files-google-drive.md](plans/files-google-drive.md) | — | Decide whether to fund one Google OAuth verification + yearly CASA assessment covering `gmail.readonly` and `drive.readonly`, or ship IMAP/app passwords, Takeout and sync folders instead. Weeks of lead time. |
| Meta business verification + App Review | `proposed` | deferred | [social-facebook-sync.md](plans/social-facebook-sync.md) §Deferred | — | Owner action (xdtlabs). Unblocks the Facebook Graph API, Instagram API and Threads API paths and the Cloud Run token service. Days to weeks for verification; review after a working build. |

## Social

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Bluesky sync | `proposed` | 2 | [social-bluesky-sync.md](plans/social-bluesky-sync.md) | — | Open AT Protocol: handle → DID → PDS, app-password sign-in, `listRecords` JSON backfill + blobs. Free, worldwide, no approval. |
| Mastodon sync | `proposed` | 2 | [social-mastodon-sync.md](plans/social-mastodon-sync.md) | — | Per-server OAuth with runtime app registration (or a pasted token); full history via the REST API; archive zip for old servers. |
| Facebook sync (scheduled export) | `proposed` | 3 | [social-facebook-sync.md](plans/social-facebook-sync.md) | — | Export-first: on-page export instructions + file picker, then a daily scheduled JSON export to Google Drive. Graph API deferred until business verification. Spike first. |
| Instagram sync (scheduled export) | `proposed` | 3 | [social-instagram-sync.md](plans/social-instagram-sync.md) | — | Export-first: a daily scheduled JSON export to Google Drive, picked up by the Drive scanner. Works for personal accounts, no App Review. API sync deferred. Spike first. |
| Threads archive | `proposed` | 3 | [social-threads-sync.md](plans/social-threads-sync.md) | — | Meta export-first, reusing the Facebook/Instagram machinery; Threads API deferred until business verification. Spike: is it schedulable? |
| Snapchat Memories import | `proposed` | 4 | [social-snapchat-memories.md](plans/social-snapchat-memories.md) | — | My Data export → Memories into Photos with dates and locations; links expire in about 7 days. |
| Flickr archive | `proposed` | 4 | [social-flickr-archive.md](plans/social-flickr-archive.md) | — | User's own free API key (OAuth 1.0a) for originals, metadata, albums and geo, with daily sync; data export as an alternative. |
| YouTube uploads via Takeout | `proposed` | 4 | [social-youtube-archive.md](plans/social-youtube-archive.md) | — | Takeout (schedulable to Drive) for uploads incl. private/unlisted, plus playlists; size controls; Data API deferred. |
| X (Twitter) sync, bring your own API key | `proposed` | 4 | [social-x-sync.md](plans/social-x-sync.md) | — | User's own X developer app, pay-per-use at $0.001/owned post read. Timeline limited to the 3,200 most recent; older posts via full-archive search or the free archive. Shares Flickr's OAuth 1.0a signer. |
| Reddit archive | `proposed` | 5 | [social-reddit-archive.md](plans/social-reddit-archive.md) | — | Data-request CSV export; own comments opt-in; personal installed-app API later (listings capped at about 1,000). |
| Pinterest archive | `proposed` | 5 | [social-pinterest-archive.md](plans/social-pinterest-archive.md) | — | Export only (API approval too slow); boards → albums, pins with images and links. |
| Tumblr archive | `proposed` | 5 | [social-tumblr-archive.md](plans/social-tumblr-archive.md) | — | Per-blog export (posts, media, drafts); API v2 sync later. |
| LinkedIn archive | `proposed` | 5 | [social-linkedin-archive.md](plans/social-linkedin-archive.md) | — | **Needs a real export first.** CSV data export (`Shares.csv`, articles) imported via on-page instructions and a file picker; no scheduling, so a re-export reminder. APIs ignored (EEA/Swiss only). |
| TikTok archive | `proposed` | 5 | [social-tiktok-archive.md](plans/social-tiktok-archive.md) | — | **Not ready: testing required.** In-app JSON export for everyone (video links only, verify they download); Data Portability API for automatic sync with media, EEA/UK users only. |
| Strava archive | `proposed` | 6 | [social-strava-archive.md](plans/social-strava-archive.md) | — | Bulk export: activities.csv + GPX/FIT tracks → routes on the map and in `near:`; FIT parsed in aiserver; personal API app later. |
| Goodreads / Letterboxd / Medium / Substack | `proposed` | 6 | [social-csv-exports.md](plans/social-csv-exports.md) | — | Small file imports of the user's reviews, logs and articles. |

## Email

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Email: Yahoo (+ AT&T) | `proposed` | 2 | [email-yahoo.md](plans/email-yahoo.md) | — | Existing; reference provider for the IMAP engine. Add AT&T's Yahoo-hosted mail. |
| Email: Outlook / Microsoft 365 | `proposed` | 2 | [email-outlook.md](plans/email-outlook.md) | — | Existing IMAP + OAuth2. Ship our own Entra app as a public PKCE client (no secret); publisher verification. |
| Email: Gmail | `proposed` | 2, 3 | [email-gmail.md](plans/email-gmail.md) | — | Existing Gmail API sync needs Google verification + yearly CASA to ship. IMAP + app password in Wave 2, Takeout import in Wave 3; the API path waits on the restricted-scope decision. |
| Email: AOL (+ Verizon.net) | `proposed` | 2 | [email-aol.md](plans/email-aol.md) | — | IMAP + app password. Registry entry only. |
| Email: iCloud | `proposed` | 2 | [email-icloud.md](plans/email-icloud.md) | — | IMAP + app-specific password; handle revocation on Apple Account password change. |
| Email: Fastmail | `proposed` | 2 | [email-fastmail.md](plans/email-fastmail.md) | — | IMAP + app password; JMAP later if needed. |
| Email: Yandex | `proposed` | 2 | [email-yandex.md](plans/email-yandex.md) | — | IMAP + app password (can take hours to activate). |
| Email: GMX / mail.com / WEB.DE | `proposed` | 2 | [email-gmx.md](plans/email-gmx.md) | — | IMAP must be switched on and turns itself off after inactivity. |
| Email: Zoho | `proposed` | 2 | [email-zoho.md](plans/email-zoho.md) | — | IMAP per data-centre region; free plan may lack IMAP (verify). |
| Email: file imports (MBOX, EML; Tuta) | `proposed` | 3 | [email-file-imports.md](plans/email-file-imports.md) | — | Streaming MBOX/EML import next to the existing PST import: Takeout, Apple Mail, Thunderbird, Proton/Tuta exports. |
| Email: Proton | `proposed` | 3 | [email-proton.md](plans/email-proton.md) | — | Paid: IMAP via Proton Mail Bridge on localhost (pinned self-signed cert). Free: export, then file import. |

## Files

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Files: Dropbox | `in-progress` | 1 | [files-dropbox.md](plans/files-dropbox.md) | — | Built in #42 (in review): PKCE sign-in, `list_folder` cursor sync, batch thumbnails, sync-folder card. Left: app registration, production approval before 50 linked users, live test. |
| Files: OneDrive / SharePoint | `in-progress` | 1 | [files-onedrive.md](plans/files-onedrive.md) | — | Built in #42 (in review): Graph `delta` sync on the Outlook Entra app, thumbnails, sync-folder card. Left: Entra app setup, work and SharePoint accounts, live test. |
| Files: iCloud Drive | `in-progress` | 1 | [files-icloud-drive.md](plans/files-icloud-drive.md) | — | Built in #42 (in review): one card for `com~apple~CloudDocs` (app containers left out by decision), dataless files, legacy `.icloud` stubs. Left: "download for indexing", Full Disk Access check. |
| Files: Proton Drive | `in-progress` | 1 | [files-proton-drive.md](plans/files-proton-drive.md) | — | Sync-folder card built in #42 (in review); folder name unverified. The SDK doesn't yet support third-party auth. Lower priority: confirming the folder name is deferred. |
| Files: MEGA | `in-progress` | 1 | [files-mega.md](plans/files-mega.md) | — | Sync-folder card built in #42 (in review); folder name unverified. MEGAcmd later. Lower priority: confirming the folder name is deferred. |
| Files: Sync.com | `in-progress` | 1 | [files-sync-com.md](plans/files-sync-com.md) | — | Sync-folder card for `~/Sync` built in #42 (in review); not tested on a real install. Lower priority: further work deferred. |
| Files: Google Drive | `in-progress` | 1 | [files-google-drive.md](plans/files-google-drive.md) | — | Existing; now on `CloudFileScanner` with change-cursor sync (#40), and the Drive app folder is a sync-folder card. Switch to the Changes API, also in Wave 1. `drive.readonly` is still restricted (verification + CASA, shared with Gmail). |
| Files: Box | `in-progress` | 1 | [files-box.md](plans/files-box.md) | — | Box Drive folder card built in #42 (in review). API via the Events cursor, also in Wave 1 (token service if a secret is required). |
| Files: pCloud | `in-progress` | 1, deferred | [files-pcloud.md](plans/files-pcloud.md) | — | pCloud Drive card built in #42 (in review); folder name unverified. Lower priority: the US/EU API with a `diff` cursor is deferred, as is confirming the folder name. |
| Files: Google Photos | `proposed` | 4 | [files-google-photos.md](plans/files-google-photos.md) | — | Takeout only: the Library API stopped reading user libraries on 31 March 2025. JSON sidecar merge for dates and geo. |
| Files: WebDAV / Nextcloud / NAS / SMB | `proposed` | 5 | [files-webdav-nas.md](plans/files-webdav-nas.md) | — | Nextcloud Login Flow v2, ETag walk, pinned self-signed certificates; offline volumes not treated as deleted. |

## Apps

Built-in application modules (rail group `app`), ported from the React prototypes in
`mockups/`. Built in Waves 8–11, after the collection work. Each plan breaks its app into phases with their own checklists.

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Calendar app: day/week/month views (from `mockups/calendar-planner`) | `proposed` | 8 | [app-calendar.md](plans/app-calendar.md) | — | A fourth collection type (`calendar`, rail group `collections`, sources added at `/calendar/add` like Email). Four connectors cover the services: Google API, Microsoft Graph, CalDAV (iCloud, Fastmail, Yahoo, Zoho, NAS…) and `.ics` links; plus file imports (`.ics`, Takeout `.zip`, `.vcs`, Outlook `.csv`, `.pst`; OLM later), like Email's PST tab. No calendars rebuilt from invitation emails. One editable local calendar; every other source adds read-only calendars toggled on/off like Google Calendar. UTC epoch-ms storage with the event's IANA zone for repeats; all-day dates stored at 00:00 UTC and never shifted. Attachments only from imports. Calendar colours from the shared `AccentPalette` (also used by Tasks). Five tables: `calendars` plus four `calendar_event*`. Phases: C0 schema + repository, C1 shell + month view, C2 week/day views (overlap layout, all-day band, now line), C3 editor, C4 drag (move, resize, create, 15-min snap) + shortcuts, C5 calendar collection type + repeating events + file import (.ics, .zip, .vcs, .csv), C6 Outlook PST calendars (Calendar folders + repeat blob; offered from Email's PST tab), C7 Google Calendar, C8 Outlook (Graph), C9 CalDAV (iCloud, Fastmail, Yahoo, NAS) + subscribed URLs, C10 repeating local events + reminders, C11 unified search + an embedding per event, C12 later (EventKit, OLM, Tasks layer, agenda/year views). |
| Tasks app: kanban boards (from `mockups/kanban-board`) | `proposed` | 9 | [app-tasks.md](plans/app-tasks.md) | — | Single-user, multiple boards, no assignees; inherits the app theme (`TaskColors` over the shared `AccentPalette`). Six tables: `tasks` plus five `task_*`. Phases: T0 schema + repository, T1 boards drawer + read-only board, T2 task editor, T3 drag/drop + reorder + keyboard, T4 search/filter + auto-hide completed (7 days, per-board setting), T5 custom columns, T6 links to emails/files/photos, T7 unified search + an embedding per task, T8 later (LLM tools, calendar, activity log). |
| Photo Editor app: adjust, crop, AI edit and generate (from `mockups/ai-photo-editor`) | `proposed` | 10 | [app-photo-editor.md](plans/app-photo-editor.md) | — | Opened from the photo viewer's Edit button and a rail entry. Non-destructive: a recipe of steps in the DB; Save writes a new file to a local Edits collection linked to the original (generated images also go to a Generated album, with prompt/model provenance). One shader renders preview and saved file. Cloud models: Nano Banana 2.x, GPT Image 2.5, Grok Imagine Image 2.0, kept as `aichat_models` rows (new `capabilities` + `image_options` columns), not code; local image models only once added in Settings. Three tables: `photo_edits`, `photo_edit_steps`, `ai_image_jobs`. Phases: E0 schema + Edits collection, E1 editor shell + viewer Edit button, E2 adjustments + presets + undo/redo, E3 crop/rotate/flip/straighten, E4 save/export/reopen with EXIF, E5 aiserver `/v1/images/*` + provider adapters + Settings image models, E6 AI edits with masked, full-resolution selections, E7 generate, E8 local image models (runtime spike), E9 later. |
| Timeline app: play back your life on a map (from `mockups/map-timeline-viewer`) | `proposed` | 11 | [app-timeline.md](plans/app-timeline.md) | — | Premiere-style lanes on one shared ruler (decades to minutes, density strips when zoomed out) under a `flutter_map` map. Drawn from the archive through a trigger-maintained `timeline_items` index, not copied. User-defined lanes (type + collections + filters); defaults: one photo lane, one per social platform, one for all GPX files, one for Strava, one flights lane, one per email collection. Smart playback: camera flies to each item, then dwells on it in a Now playing panel; tracks and flights draw along real timestamps; empty stretches play 5× faster (to be tuned). Stories are saved time ranges. Tables: `timeline_items`, `timeline_lanes`, `timeline_stories`, plus a shared `tracks` (also Strava's), `flights` and `airports`. Phases: L0 index + photo taken time, L1 map + read-only timeline, L2 lanes, L3 playback, L4 social posts, L5 stories, L6 GPS tracks, L7 flights from email + email lanes, L8 later (calendar lane, Google Maps Timeline / Location History, trip detection, story video export). |

## Other

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| Windows Recycle Bin for photo delete | `parked` | any | [windows-recycle-bin.md](plans/windows-recycle-bin.md) | — | Waiting on Windows becoming a build target. Unparks with [core-ci-windows-build.md](plans/core-ci-windows-build.md). |

## Done

| Feature | Status | Wave | Plan | ADR | Notes |
|---|---|---|---|---|---|
| LLM tool access to the archive (Gemma) | `done` | — | [llm-tools.md](plans/llm-tools.md) | [0001](adr/0001-llm-tool-registry.md) | Phases 0–5 built 2026-10-25; verified in the running app 2026-11-01 (the model calls the search tool from chat). Phase 6 (cloud models, scoped tool sets, MCP) not scheduled. |
| Photos module rewrite (from Lumina Gallery) | `done` | — | [photos-gallery-rewrite.md](plans/photos-gallery-rewrite.md) | — | Closed 2026-11-01. Timeline view, trip playback and the integration tests were dropped; the first two move to the [Timeline app](plans/app-timeline.md). |
| Photo clustering + AI group labels | `done` | — | [photo-clustering.md](plans/photo-clustering.md) | — | Phases 1–4 and C1–C2 built; verified against the real library 2026-11-01. Phase 5 (incremental assignment and regroup) and C3 (undo or a Hidden view with restore) not scheduled. |
