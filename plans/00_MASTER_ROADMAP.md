# 🗺️ Master Roadmap: mydatatools-desktop

This document tracks high-level **Campaigns** (Strategic Goals) across the project. It serves as the single source of truth for overarching project direction and status. 
*Note: Individual tasks are tracked within specific Campaign Plan files.*

## 📈 Status Definitions
*   **[Planned]**: Identified campaign, not yet started.
*   **[In Progress]**: Active development under way.
*   **[Blocked]**: Waiting on external dependencies or decisions.
*   **[Done]**: Successfully implemented and verified.

---

## 🏗️ Phase 1: Infrastructure & Technical Debt
*Campaigns focused on modernizing, stabilizing, and improving the underlying architecture.*

*   **[Planned] Campaign: Python AI Service Optimization**
    *   **Goal:** Optimize `client/assets/python/aichat/src/aichat/main.py` and FastAPI endpoints for better memory management and initialization speed with local models (Gemma, SigLip2).
    *   **Plan File:** `plans/camp_python_service_optimization.md`
*   **[Planned] Campaign: Database & Vector Search Performance**
    *   **Goal:** Improve vector indexing performance and concurrent read/write handling within `database_manager.dart` using `sqlite_vector`.
    *   **Plan File:** `plans/camp_db_vector_optimization.md`
*   **[Planned] Campaign: Dart Isolate Stabilization**
    *   **Goal:** Solidify error handling, recovery, and memory efficiency within Dart Isolates for background processing (file scanning, thumbnail generation).
    *   **Plan File:** `plans/camp_isolate_stabilization.md`

## 🚀 Phase 2: Core Feature Enhancements
*Campaigns focused on improving existing modules and user experience.*

*   **[Planned] Campaign: Unified Semantic Search**
    *   **Goal:** Improve the `aichat` module's cross-domain semantic search integration, allowing seamless querying across `files`, `email`, and `photos` modules.
    *   **Plan File:** `plans/camp_unified_search.md`
*   **[Planned] Campaign: Cache-then-Scan Pipeline Resiliency**
    *   **Goal:** Improve granular progress reporting, pausing, and resumable scanning operations for local files and cloud sources.
    *   **Plan File:** `plans/camp_cache_scan_enhancements.md`

## ✨ Phase 3: New Features
*Campaigns introducing entirely new capabilities to the application.*

*   **[Done] Campaign: Outlook Mail Integration**
    *   **Goal:** Implement IMAP synchronization and app password authentication for Microsoft Outlook/Office 365 accounts, expanding supported cloud email providers.
    *   **Plan File:** `plans/PHASE_01_OUTLOOK_MAIL.md`

*   **[Planned] Campaign: [New Feature Placeholder]**
    *   **Goal:** Implement the new user-requested feature, integrating it gracefully with the existing reactive state architecture (`RxService`), local database persistence, and AI services.
    *   **Plan File:** `plans/camp_new_feature_implementation.md`

## 🛠️ Phase 4: Maintenance & Release
*Campaigns ensuring quality, test coverage, and smooth deployments.*

*   **[Planned] Campaign: Comprehensive Test Harness Expansion**
    *   **Goal:** Significantly increase unit and integration test coverage across core Dart services, particularly focusing on reactive streams and database state changes.
    *   **Plan File:** `plans/camp_test_expansion.md`
*   **[Planned] Campaign: Release Automation Enhancement**
    *   **Goal:** Streamline macOS `.dmg` creation, Python environment bundling, and Flutter build steps via CI/CD improvements.
    *   **Plan File:** `plans/camp_ci_cd_automation.md`