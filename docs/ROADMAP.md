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
| Dropbox file source | `idea` | — | — | Constant only; provider commented out in `client/lib/file_sources/file_source_registry.dart`. |
| OneDrive file source | `idea` | — | — | Constant only; no provider or scanner. |
| Glassmorphism elevation model | `ready` | [glassmorphism-elevation.md](plans/glassmorphism-elevation.md) | — | Decision made 2026-08-01 to build out `DESIGN.md`'s spec. |
| Tier 2 auto-update (Sparkle) | `proposed` | [sparkle-auto-update.md](plans/sparkle-auto-update.md) | — | Probably needs an ADR (EdDSA key custody, appcast hosting). |
| Fix hanging `TagsAndLandmarksSection` widget test | `proposed` | [fix-tags-landmarks-widget-test.md](plans/fix-tags-landmarks-widget-test.md) | — | Test is `skip: true`; investigation notes in the plan. |
| Windows Recycle Bin for photo delete | `parked` | [windows-recycle-bin.md](plans/windows-recycle-bin.md) | — | Waiting on Windows becoming a build target. |
