# Roadmap

Every feature in flight or planned, with its status and where its details live. Status values
and how to keep this file current are explained in [README.md](README.md).

| Feature | Status | Plan | ADR | Notes |
|---|---|---|---|---|
| Photo clustering + AI group labels | `in-progress` | [photo-clustering.md](plans/photo-clustering.md) | — | Phases 1–4 and C1–C2 built and tested. Remaining: check against the real library in the running app, phase 5 (incremental assignment and regroup), C3 (undo or a Hidden view with restore). |
| Unified search | `in-progress` | [unified-search.md](plans/unified-search.md) | — | Phases 1–6 and §13 autocomplete built. Phase 7 (document extraction and chunking, §18) is designed, its spike passed, and `aiserver/src/aichat/document_extractor.py` has started it. |
| Photos module rewrite (from Lumina Gallery) | `in-progress` | [photos-gallery-rewrite.md](plans/photos-gallery-rewrite.md) | — | Most of the planned files exist with tests. Not found: Timeline view mode (`photo_timeline_view.dart`; `PhotoViewMode` has no `timeline`), `trip_playback_controller.dart`, and the `gallery_navigation`, `photo_lifecycle` and `search_and_filter` integration tests. Needs a pass to confirm whether those were dropped or are still wanted. |
| LLM tool access to the archive (Gemma) | `in-progress` | [llm-tools.md](plans/llm-tools.md) | [0001](adr/0001-llm-tool-registry.md) | Phases 0–5 built 2026-10-25; verified end to end against the real model. Left: a visual check of the chat UI in the running app. Phase 6 (cloud models, scoped tool sets, MCP) not scheduled. |
| X (Twitter) sync, bring your own API key | `proposed` | [social-x-sync.md](plans/social-x-sync.md) | — | User's own X developer app, pay-per-use at $0.001/owned post read. Timeline limited to the 3,200 most recent; older posts via full-archive search or the free archive. Defines the shared social foundation (ADR 0002). |
| Facebook sync (scheduled export) | `proposed` | [social-facebook-sync.md](plans/social-facebook-sync.md) | — | Export-first: on-page export instructions + file picker, then a daily scheduled JSON export to Google Drive. Graph API deferred until business verification. Spike first. |
| Instagram sync (scheduled export) | `proposed` | [social-instagram-sync.md](plans/social-instagram-sync.md) | — | Export-first: a daily scheduled JSON export to Google Drive, picked up by the Drive scanner. Works for personal accounts, no App Review. API sync deferred. Spike first. |
| TikTok archive | `proposed` | [social-tiktok-archive.md](plans/social-tiktok-archive.md) | — | **Not ready: testing required.** In-app JSON export for everyone (video links only, verify they download); Data Portability API for automatic sync with media, EEA/UK users only. |
| LinkedIn archive | `proposed` | [social-linkedin-archive.md](plans/social-linkedin-archive.md) | — | **Needs a real export first.** CSV data export (`Shares.csv`, articles) imported via on-page instructions and a file picker; no scheduling, so a re-export reminder. APIs ignored (EEA/Swiss only). |
| Bluesky sync (release 1) | `proposed` | [social-bluesky-sync.md](plans/social-bluesky-sync.md) | — | Open AT Protocol: handle → DID → PDS, app-password sign-in, `listRecords` JSON backfill + blobs. Free, worldwide, no approval. |
| Mastodon sync (release 1) | `proposed` | [social-mastodon-sync.md](plans/social-mastodon-sync.md) | — | Per-server OAuth with runtime app registration (or a pasted token); full history via the REST API; archive zip for old servers. |
| Threads archive (release 2) | `proposed` | [social-threads-sync.md](plans/social-threads-sync.md) | — | Meta export-first, reusing the Facebook/Instagram machinery; Threads API deferred until business verification. Spike: is it schedulable? |
| Snapchat Memories import (release 3) | `proposed` | [social-snapchat-memories.md](plans/social-snapchat-memories.md) | — | My Data export → Memories into Photos with dates and locations; links expire in about 7 days. |
| Flickr archive (release 3) | `proposed` | [social-flickr-archive.md](plans/social-flickr-archive.md) | — | User's own free API key (OAuth 1.0a) for originals, metadata, albums and geo, with daily sync; data export as an alternative. |
| YouTube uploads via Takeout (release 4) | `proposed` | [social-youtube-archive.md](plans/social-youtube-archive.md) | — | Takeout (schedulable to Drive) for uploads incl. private/unlisted, plus playlists; size controls; Data API deferred. |
| Reddit archive (release 5) | `proposed` | [social-reddit-archive.md](plans/social-reddit-archive.md) | — | Data-request CSV export; own comments opt-in; personal installed-app API later (listings capped at about 1,000). |
| Pinterest archive (release 5) | `proposed` | [social-pinterest-archive.md](plans/social-pinterest-archive.md) | — | Export only (API approval too slow); boards → albums, pins with images and links. |
| Tumblr archive (release 5) | `proposed` | [social-tumblr-archive.md](plans/social-tumblr-archive.md) | — | Per-blog export (posts, media, drafts); API v2 sync later. |
| Strava archive (release 6) | `proposed` | [social-strava-archive.md](plans/social-strava-archive.md) | — | Bulk export: activities.csv + GPX/FIT tracks → routes on the map and in `near:`; FIT parsed in aiserver; personal API app later. |
| Goodreads / Letterboxd / Medium / Substack (release 6) | `proposed` | [social-csv-exports.md](plans/social-csv-exports.md) | — | Small file imports of the user's reviews, logs and articles. |
| Email: shared IMAP engine | `proposed` | [email-imap-engine.md](plans/email-imap-engine.md) | — | Merge the ~90%-identical Yahoo/Outlook isolates into one `ImapScanner` + provider registry; UID/CONDSTORE incremental sync; one setup flow with autodetect. Prerequisite for the provider rows below. |
| Email: Gmail | `proposed` | [email-gmail.md](plans/email-gmail.md) | — | Existing Gmail API sync needs Google verification + yearly CASA to ship. Proposal: IMAP + app password and Takeout import first. |
| Email: Outlook / Microsoft 365 | `proposed` | [email-outlook.md](plans/email-outlook.md) | — | Existing IMAP + OAuth2. Ship our own Entra app as a public PKCE client (no secret); publisher verification. |
| Email: Yahoo (+ AT&T) | `proposed` | [email-yahoo.md](plans/email-yahoo.md) | — | Existing; reference provider for the IMAP engine. Add AT&T's Yahoo-hosted mail. |
| Email: AOL (+ Verizon.net) | `proposed` | [email-aol.md](plans/email-aol.md) | — | IMAP + app password. Registry entry only. |
| Email: iCloud | `proposed` | [email-icloud.md](plans/email-icloud.md) | — | IMAP + app-specific password; handle revocation on Apple Account password change. |
| Email: Proton | `proposed` | [email-proton.md](plans/email-proton.md) | — | Paid: IMAP via Proton Mail Bridge on localhost (pinned self-signed cert). Free: export, then file import. |
| Email: Fastmail | `proposed` | [email-fastmail.md](plans/email-fastmail.md) | — | IMAP + app password; JMAP later if needed. |
| Email: Zoho | `proposed` | [email-zoho.md](plans/email-zoho.md) | — | IMAP per data-centre region; free plan may lack IMAP (verify). |
| Email: GMX / mail.com / WEB.DE | `proposed` | [email-gmx.md](plans/email-gmx.md) | — | IMAP must be switched on and turns itself off after inactivity. |
| Email: Yandex | `proposed` | [email-yandex.md](plans/email-yandex.md) | — | IMAP + app password (can take hours to activate). |
| Email: file imports (MBOX, EML; Tuta) | `proposed` | [email-file-imports.md](plans/email-file-imports.md) | — | Streaming MBOX/EML import next to the existing PST import: Takeout, Apple Mail, Thunderbird, Proton/Tuta exports. |
| Dropbox file source | `idea` | — | — | Constant only; provider commented out in `client/lib/file_sources/file_source_registry.dart`. |
| OneDrive file source | `idea` | — | — | Constant only; no provider or scanner. |
| Glassmorphism elevation model | `ready` | [glassmorphism-elevation.md](plans/glassmorphism-elevation.md) | — | Decision made 2026-08-01 to build out `DESIGN.md`'s spec. |
| Tier 2 auto-update (Sparkle) | `proposed` | [sparkle-auto-update.md](plans/sparkle-auto-update.md) | — | Probably needs an ADR (EdDSA key custody, appcast hosting). |
| Fix hanging `TagsAndLandmarksSection` widget test | `proposed` | [fix-tags-landmarks-widget-test.md](plans/fix-tags-landmarks-widget-test.md) | — | Test is `skip: true`; investigation notes in the plan. |
| Windows Recycle Bin for photo delete | `parked` | [windows-recycle-bin.md](plans/windows-recycle-bin.md) | — | Waiting on Windows becoming a build target. |
