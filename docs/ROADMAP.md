# Roadmap

Every feature in flight or planned, with its status and where its details live. Status values
and how to keep this file current are explained in [README.md](README.md).

| Feature | Status | Plan | ADR | Notes |
|---|---|---|---|---|
| Photo clustering + AI group labels | `in-progress` | [photo-clustering.md](plans/photo-clustering.md) | — | Phases 1–4 and C1–C2 built and tested. Remaining: check against the real library in the running app, phase 5 (incremental assignment and regroup), C3 (undo or a Hidden view with restore). |
| Unified search | `in-progress` | [unified-search.md](plans/unified-search.md) | — | Phases 1–6 and §13 autocomplete built. Phase 7 (document extraction and chunking, §18) is designed, its spike passed, and `aiserver/src/aichat/document_extractor.py` has started it. |
| Photos module rewrite (from Lumina Gallery) | `in-progress` | [photos-gallery-rewrite.md](plans/photos-gallery-rewrite.md) | — | Most of the planned files exist with tests. Not found: Timeline view mode (`photo_timeline_view.dart`; `PhotoViewMode` has no `timeline`), `trip_playback_controller.dart`, and the `gallery_navigation`, `photo_lifecycle` and `search_and_filter` integration tests. Needs a pass to confirm whether those were dropped or are still wanted. |
| LLM tool access to the archive (Gemma) | `in-progress` | [llm-tools.md](plans/llm-tools.md) | [0001](adr/0001-llm-tool-registry.md) | Phases 0–1 done 2026-10-25: auto mode passed the gate (97% right tool, 100% valid args); aiserver accepts and returns tool calls. Next: Phase 2 (stateless `ArchiveSearch`). External MCP adapter deferred. |
| Twitter / X archive import | `proposed` | [social-twitter-archive.md](plans/social-twitter-archive.md) | — | Build first: it defines the shared social foundation (schema, import isolate, search) the other two reuse. Likely ADR 0002. |
| Facebook sync (Graph API) | `proposed` | [social-facebook-sync.md](plans/social-facebook-sync.md) | — | Archive of the user's own posts, photos and check-ins. Needs Meta App Review + a token-exchange service on Cloud Run. Builds the shared social foundation. |
| Instagram archive import | `proposed` | [social-instagram-archive.md](plans/social-instagram-archive.md) | — | Depends on the shared social foundation. Mostly media, which lands in Photos. |
| Dropbox file source | `idea` | — | — | Constant only; provider commented out in `client/lib/file_sources/file_source_registry.dart`. |
| OneDrive file source | `idea` | — | — | Constant only; no provider or scanner. |
| Glassmorphism elevation model | `ready` | [glassmorphism-elevation.md](plans/glassmorphism-elevation.md) | — | Decision made 2026-08-01 to build out `DESIGN.md`'s spec. |
| Tier 2 auto-update (Sparkle) | `proposed` | [sparkle-auto-update.md](plans/sparkle-auto-update.md) | — | Probably needs an ADR (EdDSA key custody, appcast hosting). |
| Fix hanging `TagsAndLandmarksSection` widget test | `proposed` | [fix-tags-landmarks-widget-test.md](plans/fix-tags-landmarks-widget-test.md) | — | Test is `skip: true`; investigation notes in the plan. |
| Windows Recycle Bin for photo delete | `parked` | [windows-recycle-bin.md](plans/windows-recycle-bin.md) | — | Waiting on Windows becoming a build target. |
