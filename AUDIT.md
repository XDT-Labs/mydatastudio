# Application Audit — My Data Studio Desktop

> Comprehensive audit covering security, reliability, concurrency, accessibility, UI
> consistency, and module completeness. Findings are grouped by severity with checkboxes
> so work can be tracked across multiple sessions.
>
> **How to use this file:** Each finding has a `- [ ]` checkbox. Tick it when fixed, and
> add a note (commit SHA / date) under the finding. Nothing here has been modified in the
> codebase yet — this is a report only.

**Audit date:** 2026-07-10
**Branch:** `claude/audit-application-6aa50c`

---

## Scope reviewed

- **Python AI server (`aiserver/`)** end-to-end: routes, global state, utils (downloads/file I/O), PST parser, Pydantic models.
- **Flutter client security surface:** OAuth managers, encryption helper, credential storage, subprocess (`PythonManager`), DB layer.
- **AI-chat streaming flow** (client `LocalLlmContentGenerator` ⇄ server SSE).
- **Scanners** (isolate concurrency, dedup).
- **UI / accessibility** across the five feature modules: aichat, email, files, photos, social.

**Method:** Traced the two runtime components and their trust boundary (Flutter ⇄ localhost HTTP) end-to-end. No code was modified.

---

## Overall posture

The **path-traversal defenses on model loading/deletion are genuinely good** (`_assert_within_models_dir`, `_safe_repo_path`, tar-member validation) and **all SQL is parameterized** (no injection found — every raw query uses `?` placeholders). The real weaknesses are:

1. The localhost server has **no authentication** while exposing file-read and file-write primitives.
2. **Third-party credentials are stored in plaintext** (OAuth refresh tokens, cloud API keys, OAuth client secrets).
3. A **chat double-submit race** via the Enter key corrupts conversation state.

Accessibility is essentially unimplemented (zero `Semantics` widgets). Two modules (social, photos) are stubs.

---

## Findings index

| ID | Severity | Category | Title |
|----|----------|----------|-------|
| H1 | High | Security | Local AI server exposes file read/write with no authentication |
| H2 | High | Security | Arbitrary local file read via `/util/thumbnail` |
| M1 | Medium | Security | Arbitrary directory creation / file write via `/util/import/pst` |
| M2 | Medium | Security | Third-party credentials stored in plaintext SQLite |
| M3 | Medium | Race Condition | Chat double-submit race via the Enter key |
| M4 | Medium | Accessibility | No screen-reader / semantic layer |
| L1 | Low | Security | Exception text leaked to client (thumbnail) |
| L2 | Low | Race Condition | Global stop flag is process-wide |
| L3 | Low | Reliability | Single global `llm_instance`, not concurrency-safe |
| L4 | Low | Reliability | PID-file kill can target a reused PID |
| L5 | Low | Reliability | `dispose()` doesn't cancel in-flight request |
| I1 | Info | Visual | Hardcoded colors bypass the theme |
| I2 | Info | Security | CORS `allow_headers=["*"]` broader than needed |
| I3 | Info | Reliability | Stale `//todo` env wiring in PythonManager |

---

## HIGH

### - [x] H1 — Local AI server exposes file read/write with no authentication
- **Category:** Security · **Confidence:** Confirmed
- **Location:** `aiserver/src/aichat/main.py:126-158` (no auth dependency on any route); binds `127.0.0.1:0` at `main.py:202`
- **Issue:** The server accepts any request to `127.0.0.1:<port>` with no token, API key, or origin enforcement for non-browser clients. CORS (`allow_origins` localhost) only constrains browsers; any other local process that discovers the port has full access.
- **Impact:** Combined with H2/M1, any local process (or malware running as the user) can read arbitrary image files and write files to arbitrary directories through this server. The port is discoverable (printed to stderr; any process can scan localhost).
- **Evidence:** No `Depends(...)` auth guard anywhere in `main.py`; `HF_TOKEN`/`GOOGLE_API_KEY` are passed empty and the server trusts request bodies fully.
- **Recommended fix:** Generate a random bearer token at spawn time, pass it to the subprocess via env (e.g. `AISERVER_TOKEN`), require it on every route via a FastAPI dependency, and have the Flutter client attach it (`python_manager.dart` env map + `local_llm_content_generator.dart` headers). Single highest-leverage fix — closes H2/M1's exploitability.
- **Notes:** DONE 2026-07-10. Server: new `aiserver/src/aichat/auth.py` (`require_token` dependency, constant-time compare, disabled when `AISERVER_TOKEN` unset for dev/tests), applied app-wide via `dependencies=[Depends(require_token)]` in `main.py`. Client: `PythonManager` generates 32-byte CSPRNG hex token, passes it via `AISERVER_TOKEN` env, and broadcasts it on `MainApp.llmServiceToken`; a shared `aiServerAuthHeaders(token)` helper (main.dart) attaches `Authorization: Bearer` at every call site — chat completions/stop, embeddings, model status/download/delete, thumbnail, and PST import. Worker isolates (embedding, local-file scan, PST) receive the token through their spawn args / control messages the same way they already receive the URL. Added `tests/test_auth.py` (6 passing). `flutter analyze` clean on all touched Dart files (only pre-existing lints remain). This shrinks H2/M1 exposure from "any local process" to "only the paired client" — but does **not** by itself fix the path-traversal primitives (H2/M1 still open).

### - [x] H2 — Arbitrary local file read via `/util/thumbnail`
- **Category:** Security · **Confidence:** Confirmed
- **Location:** `aiserver/src/aichat/routes.py:683-709`
- **Issue:** `request.file_path` is passed straight to `os.path.exists` / `Image.open` / `rawpy.imread` with no restriction to an allowed directory. Returns the image base64-encoded.
- **Impact:** Any caller (see H1) can exfiltrate the contents of any image file the app user can read (`~/Pictures`, screenshots, other apps' caches).
- **Reproduction:** `POST /util/thumbnail {"file_path":"/Users/<user>/some/private.png","width":9999,"height":9999}` → response `thumbnail` field is the rendered file.
- **Recommended fix:** Constrain `file_path` to the configured collection/storage roots via the same `realpath` + `commonpath` pattern already used in `_assert_within_models_dir` (`routes.py:639-646`).
- **Notes:** DONE 2026-07-22. `generate_thumbnail` now confines `file_path` (via new `_assert_within_roots`, which realpaths first so symlink escapes are caught, and requires a trailing `os.sep` so `/a/b` can't be escaped via `/a/bc`) to the union of `resolve_data_roots()` (app-support + storage/database from `config.json` + models dir — all server-derived) **and** a client-declared `allowed_root`. The local-file scanner now passes the collection `rootPath` as `allowed_root` (threaded `local_file_isolate → ThumbnailGenerator.pathImageToBase64 → request body`), so in-place external collections (e.g. `~/Pictures`) still get RAW thumbnails with **no regression**. Tests: `tests/test_path_confinement.py` (inside/outside/sibling-prefix/symlink/empty-roots). **Interim caveat:** because in-place collections can be any path, the declared root is client-supplied, so this has limited teeth against a *fully compromised* client that forges `allowed_root` — but post-H1 such a caller already runs as the user and can read files directly. The full structural fix (client sends bytes, server never opens a path) lands with the thumbnail-cache refactor below.

---

## MEDIUM

### - [x] M1 — Arbitrary directory creation / file write via `/util/import/pst`
- **Category:** Security · **Confidence:** Confirmed
- **Location:** `aiserver/src/aichat/routes.py:712-731`; writes at `aiserver/src/aichat/pst_parser.py:310-335`
- **Issue:** `output_dir` is caller-controlled and unrestricted. `os.makedirs(attachment_folder, exist_ok=True)` (`pst_parser.py:311`) runs **before** the containment check, and `folder_path` derives from attacker-controllable PST folder names. The final write is guarded by `real_path.startswith(real_output)` (line 328), but `startswith` is a prefix test (`/a/b` matches `/a/bc`) and the directory is created regardless of that check.
- **Impact:** A caller can create directories anywhere the process can write; a crafted PST combined with an attacker-chosen `output_dir` can write attachment files outside the intended tree.
- **Recommended fix:** Restrict `output_dir` to an allowed base (as in H2); apply the containment check to `attachment_folder` **before** `makedirs`; replace `startswith(base)` with `startswith(base + os.sep)` (already done correctly in `_safe_repo_path` in `utils.py` — reuse it).
- **Notes:** DONE 2026-07-22. Three fixes: (1) `import_pst` now confines `output_dir` to `resolve_data_roots()` (server-derived app-support + storage/database dirs) via `_assert_within_roots` — strong, no client trust needed, and PST output legitimately lives under `<storage>/files/email/` so no regression. (2) In `pst_parser.py` the `attachment_folder` containment check now runs **before** `os.makedirs` (a hostile PST folder name that would escape `output_dir` skips creation entirely). (3) Both the folder and per-file checks now use `startswith(real_output + os.sep)` instead of a bare prefix. Covered by `tests/test_path_confinement.py` (`_assert_within_roots` + `resolve_data_roots` from `config.json`).

### - [ ] M2 — Third-party credentials stored in plaintext SQLite
- **Category:** Security · **Confidence:** Confirmed
- **Location:**
  - OAuth tokens: `client/lib/database_manager.dart:833-834` (`access_token`, `refresh_token`), written by `client/lib/repositories/collection_repository.dart:48-90`.
  - Cloud API keys + OAuth client secrets: `providers` table (`client/lib/database_manager.dart:947`), written by `client/lib/modules/aichat/pages/aichat_models_settings_page.dart:154-189`.
  - DB opened with no SQLCipher/encryption: `client/lib/database_manager.dart:234-267`.
- **Issue:** Long-lived Gmail/Drive/Outlook/Yahoo **refresh tokens**, cloud LLM **API keys** (Claude/OpenAI/Gemini/Grok/HuggingFace), and OAuth **client secrets** are all persisted in cleartext. `flutter_secure_storage` (Keychain) is used only for the app's own login secret (`client/lib/widgets/login_form.dart:35`), not for these.
- **Impact:** Any process running as the user, a Time Machine/backup, or a synced folder exposes credentials that grant standing access to the user's email and cloud accounts. Directly undercuts the app's "local-first / private" positioning.
- **Recommended fix:** Also affects the RSA `private.pem` at `<storage>/keys/private.pem`, which is stored in cleartext with the same exposure. Chosen approach: **app-level envelope encryption** (single master key encrypts the credentials + the private key at rest) rather than SQLCipher or plain Keychain-per-secret — see the **"Planned: credential encryption (M2)"** section below for the full plan and rationale.
- **Notes:** Design settled 2026-07-22 (not yet implemented). SQLCipher rejected: the DB layer is **resqlite** (`resqlite`/`resqlite_vector`), which has no SQLCipher support, and the Python server reads the DB (`model_registry.py`) so it would also need to decrypt; full-DB crypto would also encrypt GBs of non-secret embeddings to protect KBs of secrets. See plan below.

### - [x] M3 — Chat double-submit race via the Enter key  ✅ FIXED (quick-win pass)
- **Category:** Race Condition / Reliability · **Confidence:** Confirmed
- **Location:** `client/lib/modules/aichat/pages/aichat_page.dart:528-535` (`_handleKeyEvent`); guard `_canSend` at `aichat_page.dart:94-95`; no re-entrancy guard in `client/lib/modules/aichat/services/local_llm_content_generator.dart:96-104`.
- **Issue:** The on-screen button correctly swaps to a Stop button while streaming, but the Enter key handler calls `_sendMessage` unconditionally. `_canSend` checks only that text/attachments exist — **not** whether a response is already streaming. `sendRequest` has no guard: a second call overwrites `_activeClient`, appends a second user message to `_messages` mid-stream, and both streams write to the same controllers.
- **Impact:** Pressing Enter (or holding it) during generation corrupts conversation history, orphans the first HTTP connection, and produces interleaved/garbled output. The persisted conversation and in-memory `_messages` diverge.
- **Reproduction:** Send a prompt that yields a long response; while it streams, type in the field and press Enter.
- **Recommended fix:** Gate `_handleKeyEvent` on `!_contentGenerator.isProcessing.value && _canSend`, and add an early-return guard at the top of `sendRequest` (`if (_isProcessing.value) return;`).
- **Notes:** Fixed — `_handleKeyEvent` now checks `_canSend && !_contentGenerator.isProcessing.value` (`aichat_page.dart`), and `sendRequest` returns early if already processing (`local_llm_content_generator.dart`). `flutter analyze` clean.

### - [ ] M4 — No screen-reader / semantic layer
- **Category:** Accessibility · **Confidence:** Confirmed
- **Location:** App-wide — `grep` for `Semantics(` returns **0** matches across `client/lib/`. Send control is a bare `GestureDetector` at `client/lib/modules/aichat/pages/aichat_page.dart:1055-1072`.
- **Issue:** Icon-only `IconButton`s (14) rely on tooltips (18) that VoiceOver reads inconsistently; the primary send/stop control is a `GestureDetector` with no accessible name, no focus semantics, and a 30×30 hit target (below the 44×44 WCAG 2.2 target-size minimum). Custom controls are invisible to macOS VoiceOver.
- **Impact:** Not operable via assistive technology; fails WCAG 2.2 AA — 4.1.2 (Name/Role/Value), 2.5.8 (Target Size), 2.4.7 (Focus Visible).
- **Recommended fix:** Replace custom tap targets with `IconButton`/`InkWell` wrapped in `Semantics(button: true, label: ...)`, enforce ≥44px targets, and add `Semantics` labels to icon-only actions.
- **Notes:**

---

## LOW

### - [x] L1 — Exception text leaked to client (thumbnail)  ✅ FIXED (quick-win pass)
- **Category:** Security · **Confidence:** Confirmed
- **Location:** `aiserver/src/aichat/routes.py:709`
- **Issue:** Returns `detail=f"Failed to generate thumbnail: {e}"`, leaking filesystem paths / library internals. Other handlers correctly return generic messages.
- **Recommended fix:** Return a generic message; log the detail server-side only. Make consistent with the other route handlers.
- **Notes:** Fixed — `detail` is now `"Failed to generate thumbnail."`; the exception is still logged via `print(...)` server-side (`routes.py`).

### - [ ] L2 — Global stop flag is process-wide
- **Category:** Race Condition · **Confidence:** Confirmed
- **Location:** `aiserver/src/aichat/state.py:150-160`; used at `aiserver/src/aichat/routes.py:167` and `routes.py:452`.
- **Issue:** A single `threading.Event`. `reset_stop()` fires at each stream start, and `request_stop()` sets it globally. A stop from one request halts all active streams; a new stream clears another's pending stop.
- **Impact:** Low for a single-user desktop app, but latent if concurrent streams ever happen.
- **Recommended fix:** Track stop state per request/generation id rather than a single global event.
- **Notes:**

### - [ ] L3 — Single global `llm_instance`, not concurrency-safe
- **Category:** Reliability · **Confidence:** High Confidence
- **Location:** `aiserver/src/aichat/routes.py:425-464`; state in `aiserver/src/aichat/state.py`.
- **Issue:** `llama_cpp.Llama.create_chat_completion` is not safe for concurrent calls; streaming runs outside `model_lock`. Two concurrent chats to the same model would corrupt decoder state.
- **Impact:** Single-window UI makes this unlikely today; would surface with multi-window or programmatic concurrent use.
- **Recommended fix:** Serialize generation (per-model lock/queue) or pool instances if concurrency is desired.
- **Notes:**

### - [ ] L4 — PID-file kill can target a reused PID
- **Category:** Reliability · **Confidence:** Needs Verification
- **Location:** `client/lib/python_manager.dart:104-119`
- **Issue:** `Process.killPid(oldPid, sigkill)` trusts a stale PID file; the OS may have recycled that PID to an unrelated process.
- **Recommended fix:** Validate process identity before killing (e.g. check the process name/command), or only SIGKILL after a liveness + identity check.
- **Notes:**

### - [x] L5 — `dispose()` doesn't cancel in-flight request  ✅ FIXED (quick-win pass)
- **Category:** Reliability · **Confidence:** Confirmed
- **Location:** `client/lib/modules/aichat/services/local_llm_content_generator.dart:88-94`
- **Issue:** Closes controllers but not `_activeClient`; navigating away mid-stream leaks the connection until the server finishes.
- **Recommended fix:** Close `_activeClient` and optionally POST `/v1/chat/stop` in `dispose()`.
- **Notes:** Fixed — `dispose()` now sets `_cancelled = true` and closes/nulls `_activeClient` before closing controllers (`local_llm_content_generator.dart`).

---

## INFORMATIONAL / VISUAL CONSISTENCY

### - [x] I1 — Hardcoded colors bypass the theme  ✅ FIXED where it was a real bug (quick-win pass)
- **Category:** Visual Consistency
- **Location:** `client/lib/modules/aichat/pages/aichat_page.dart:1049,1068`; `client/lib/modules/files/widgets/file_collection_setup/coming_soon_tab_view.dart`; `client/lib/modules/photos/widgets/photo_card.dart`.
- **Issue:** `Colors.black`, `Colors.grey.shade300` used directly instead of `Theme.of(context).colorScheme` tokens — render poorly / illegibly in dark mode.
- **Recommended fix:** Swap literal colors for `colorScheme` tokens.
- **Notes / scope correction after closer review:**
  - **`coming_soon_tab_view.dart` — FIXED.** This renders on a normal themed surface; grey-on-dark was genuinely low-contrast. Now uses `colorScheme.onSurfaceVariant` (with 0.4 alpha for the icon).
  - **`photo_card.dart` — NOT a bug, left as-is.** The `Colors.black` letterbox and white-on-`Colors.black26` caption are intentional image-presentation colors that must stay fixed regardless of app theme (they sit over arbitrary photo content). Swapping to theme tokens would *reduce* legibility.
  - **`aichat_page.dart` send button — deliberately hardcoded-dark component, left as-is.** The whole page uses a fixed dark palette (`_sendEnabledBg`, `_mutedColor`, `Color(0xFF2C2C2E)`, etc.). The `Colors.black` icon is black-on-light-button by design; an isolated token swap risks an invisible icon. Retheming this page is a **separate, non-quick-win task** — tracked below.

### - [ ] I2 — CORS `allow_headers=["*"]` broader than needed
- **Category:** Security
- **Location:** `aiserver/src/aichat/main.py:138`
- **Recommended fix:** Tighten allowed headers once auth (H1) lands.
- **Notes:**

### - [x] I3 — Stale `//todo` env wiring in PythonManager  ✅ FIXED (quick-win pass)
- **Category:** Reliability
- **Location:** `client/lib/python_manager.dart:155-158`
- **Issue:** `HF_TOKEN`/`GOOGLE_API_KEY` are passed empty; keys actually flow per-request. Dead env vars are misleading.
- **Recommended fix:** Remove the unused env entries.
- **Notes:** Fixed — removed both empty env entries, replaced with a comment pointing at the per-request key flow. Verified safe: the server reads `GOOGLE_API_KEY` only via `os.environ.get(...)` with an `or` fallback (`model_manager.py:37`), so empty-string vs absent is behaviorally identical.

---

## Missing / inconsistent functionality by module

| Module | State | Gap |
|--------|-------|-----|
| **files** (52 files, ~8.8k LOC) | Mature | Google Drive + local FS work; other providers show `ComingSoonTabView` (`client/lib/modules/files/widgets/file_collection_setup/coming_soon_tab_view.dart`). |
| **email** (35 files, ~6.8k LOC) | Mature | Gmail/Yahoo/Outlook/PST scanners present; **targeted PST-folder scanning not implemented** (`client/lib/modules/email/services/scanners/outlook_pst_scanner_isolate.dart:59`). |
| **aichat** (5 files, ~2.7k LOC) | Functional | Works; carries M3 race and the M4 a11y gaps. |
| **photos** (5 files, ~413 LOC) | Minimal | Basic list/card only; two `// TODO: disable if no files are checked` (`client/lib/modules/photos/photos_app.dart:68,78`); no album/dedup/search parity with files. |
| **social** (5 files, ~531 LOC) | **Stub** | Facebook/Twitter/Instagram pages render a literal `Text("Facebook Page")` (`client/lib/modules/social/pages/facebook_page.dart:19-21`) — no ingestion, storage, or display. |

### - [ ] Module task: implement the social module (Facebook / Twitter / Instagram)
Currently placeholder pages only. Needs ingestion, storage (Drift tables), and display, ideally on the shared scanner base below.

### - [ ] Module task: bring photos to parity with files
Add album/dedup/search; resolve the two `TODO: disable if no files are checked` in `photos_app.dart`.

### - [ ] Module task: implement targeted PST-folder scanning
`outlook_pst_scanner_isolate.dart:59` — currently scans the whole archive only.

### - [ ] Convergence: unify the scanner pattern across modules
`email` and `files` each re-implement the same isolate-scanner + upsert + embedding pattern (`*_scanner_isolate.dart`, `batch_file_upsert_service`, `folder_upsert_service`). `photos` and `social` should be built on a shared `CollectionScanner` base rather than additional variants. Standardize one lifecycle: **discover → dedup by path/hash → upsert → embed**, and have all modules consume it.

---

## Prioritized remediation plan

1. ~~**H1 — Add a bearer token to the local server**~~ ✅ DONE 2026-07-10 (env-passed per-spawn secret + FastAPI dependency + client headers). See H1 notes.
2. ~~**H2 / M1 — Confine `/util/thumbnail` and `/util/import/pst` paths**~~ ✅ DONE 2026-07-22 (`_assert_within_roots` + `resolve_data_roots`; PST containment moved before `makedirs`; client passes collection root as `allowed_root`). See H2/M1 notes.
3. **M2 — Move tokens + API keys to Keychain** (`flutter_secure_storage`) or SQLCipher, with migration.
4. **M3 — Guard chat re-entrancy** (Enter-key + `sendRequest` early return).
5. **M4 — Accessibility pass** on interactive controls (semantic buttons, labels, target sizes).
6. **L1–L5, I1–I3** — cleanup.

## Quick wins (low regression risk) — ✅ DONE 2026-07-10
- [x] **M3** guard: `_handleKeyEvent` condition + `sendRequest` early return.
- [x] **L1**: generic thumbnail error message.
- [x] **I1**: `colorScheme` tokens in `coming_soon_tab_view.dart`. (photo_card & aichat send button intentionally left — see I1 notes.)
- [x] **L5**: close `_activeClient` in `dispose()`.
- [x] **I3**: delete the dead `HF_TOKEN`/`GOOGLE_API_KEY` env entries.

All five verified: `flutter analyze` clean on the four touched Dart files; `routes.py` passes an `ast.parse` syntax check. No tests were run beyond static analysis — a manual smoke test of the chat send/stop flow is worth doing before shipping.

### - [ ] Follow-up (not a quick win): retheme `aichat_page.dart` to `colorScheme` tokens
The chat page uses a fixed hardcoded-dark palette (`_sendEnabledBg`, `_mutedColor`, `Color(0xFF2C2C2E)`, `Colors.black` icons). Converting it to theme tokens so it honors light/dark mode is a page-wide refactor with real regression surface — do it deliberately, not as a quick win.

## Requires deeper work / architectural change
- ~~**H1 token scheme**~~ ✅ DONE 2026-07-10 (touched spawn, all routes, and every client call site + worker isolates).
- ~~**H2/M1 path confinement**~~ ✅ DONE 2026-07-22. Interim for H2: the thumbnail read is confined to server-derived data roots + a client-declared collection root. Full structural elimination is folded into the **thumbnail-cache refactor** below (client sends bytes → server never opens a path).
- **M2 credential storage** (migration of existing plaintext tokens + key management).
- **M4 accessibility** (systematic, every module).
- **L2/L3 server concurrency** (per-request stop signaling + serialize or pool model access) — only if multi-stream usage becomes real.
- **social/photos modules** — net-new feature work on a shared scanner base.

---

## Planned refactor: on-disk thumbnail cache (deferred)

**Why.** Thumbnails are currently stored **as base64 text inline in the SQLite `files.thumbnail` column** for local files and email attachments (no on-disk cache), and as a **remote Google URL** for Google Drive (fetched live at render time). Two problems: (1) base64 is ~33% larger than the raw bytes and rides along on every `SELECT` of the `files` table — for a 100k-photo archive that's several GB of blobs bloating the DB and slowing queries; (2) the Google Drive path makes live network calls to Google at render time (against the local-first ethos) and those `thumbnailLink` URLs are auth-scoped and expire.

**Target design.**
- Store generated thumbnails on disk at `<app storage>/thumbnails/<collectionId>/<fileId>.webp` (use collection **id** and file **id**, not names — stable and path-safe; optionally shard by the first 2 chars of the file id to avoid 100k entries in one dir).
- The DB `files.thumbnail` column holds a short **relative** key (or just a "generated" flag), never bytes — so moving the storage dir doesn't break it, and `SELECT`s stay cheap.
- Render with `Image.file` for local, keep `Image.network` only for the (optional) Drive case.

**Pipeline changes.**
- Non-RAW local + email attachments: `ThumbnailGenerator` writes the resized WebP/JPEG to the cache dir (client-side, no server) and records the key.
- RAW local: **switch the server call from sending a `file_path` to sending the image bytes** (mirrors the existing `/util/embedding` `image_base64` contract). The server decodes from the buffer and returns bytes; it never opens a path. **This structurally eliminates H2** — the interim `allowed_root` confinement (and the whole `_assert_within_roots` call in `generate_thumbnail`) can then be removed. Cost: base64-POSTing a 20–50 MB RAW per image on the background scan.
- Google Drive: keep the `thumbnailLink` URL for now; optionally, later, download+cache into the same `thumbnails/` dir for a fully-local, consistent model.

**Edge cases to handle.**
- **Invalidation:** regenerate when the source file's `dateLastModified` (or a content hash) changes; delete cached thumbnails when the file or its collection is deleted.
- **Missing-file fallback:** DB says "has thumbnail" but the file is gone → regenerate on demand.
- **Network / removable storage:** the storage dir can be a network volume (see the WAL-probe logic in `database_manager.dart`); thousands of tiny files on a network mount are slow — consider a local fast-path or batching.
- **Migration:** simplest is lazy — ignore existing base64 rows and regenerate to disk on the next scan/view, rather than a one-time bulk convert.

**Scope (touches):** `models/tables/file.dart` + the `files` table DDL/migration in `database_manager.dart`; `thumbnail_generator.dart`; `local_file_isolate.dart`; the render widgets (`file_table.dart`, `thumbnail_widget.dart`, `photo_card.dart`); the aiserver `/util/thumbnail` handler (bytes in, bytes out) and `models.py`. Bigger than the surgical H2/M1 patches — plan and test deliberately.

---

## Planned: credential encryption (M2) — envelope encryption (deferred)

**Goal.** Get long-lived secrets out of cleartext at rest: OAuth **access/refresh tokens** (`collections`), cloud LLM **API keys** + OAuth **client secrets** (`providers`), and the RSA **`private.pem`** in `<storage>/keys/` — which today has the exact same plaintext exposure and must be fixed in the same pass.

**Approach chosen: app-level envelope encryption.** One symmetric **master key** encrypts everything sensitive; only the master key needs OS-level protection.

**Why not the alternatives (decided 2026-07-22):**
- **SQLCipher (full-DB):** the DB layer is **resqlite**/`resqlite_vector` with no SQLCipher support (would mean forking/replacing the DB stack); the **Python** server reads the DB (`model_registry.py`) so it would also need to decrypt; and it would encrypt gigabytes of non-secret embeddings to protect kilobytes of secrets. Rejected.
- **Keychain per-secret (`flutter_secure_storage` for each value):** viable for `providers.*` (main-isolate only), but `collections.*_token` are read/refreshed **inside background isolates** (`embedding_isolate`, scanners) → needs Keychain access from isolates (feasibility risk on macOS) or a token-refresh restructure. Also can't protect `private.pem`, and gives no backup/migration story. Rejected as the primary mechanism (envelope encryption subsumes it).

**Design.**
- **`SecureVault` service** (new, `client/lib/services/secure_vault.dart` or `helpers/`): holds the in-memory master key for the session; exposes `encrypt(bytes)`/`decrypt(bytes)` using **AES-256-GCM** (random 12-byte nonce per value, authenticated; via the existing `encrypt`/`pointycastle` deps). Never logs key or plaintext.
- **Master key — one decision to make (see below):**
  - **(A) Keychain-held:** generate a random 32-byte key, store only it via `flutter_secure_storage` (the app already uses it for the login secret). Strongest at-rest; **no** folder-copy migration (re-auth on a new machine — same as today's login secret).
  - **(B) Password-derived:** derive the master key from the user's app password via **PBKDF2** (the login flow already runs PBKDF2 — use a **separate salt**, never reuse the auth hash as the encryption key). Enables true "copy the storage folder + know your password" portability; **forgotten password = unrecoverable secrets** (user re-auths / re-enters keys).
  - A hybrid is possible later (Keychain master key + optional password-wrapped export for migration).
- **What gets encrypted:** the credential columns (`collections.access_token/refresh_token/id_token`, `providers.api_key/client_secret`) stored as GCM ciphertext blobs, decrypted only in memory; and `private.pem` re-written encrypted (fixes the plaintext-private-key bug). Public key stays cleartext.
- **Isolate plumbing:** the master key is read once in the **main isolate** and passed into worker isolates via their existing spawn args / control messages — exactly the pattern used for the aiserver token (H1). **No `flutter_secure_storage` calls inside isolates.** Token *refresh* writes (embedding_isolate/scanners) encrypt with the passed-in key before persisting.
- **Migration (one-time, on first launch after the change):** for each row with a non-empty plaintext secret, encrypt-in-place and rewrite; decrypt `keys/private.pem` from disk and rewrite encrypted. Guard with a `schema/vault` version flag so it runs once. Keep a read fallback that treats a value as plaintext if it fails GCM auth (so a half-migrated DB still works), removed after the migration window.

**Edge cases / risks.**
- **Python side:** `model_registry.py` only reads `aichat_models` (no secrets) — unaffected, stays on the plaintext-readable DB. Confirm no future Python reader needs an encrypted column.
- **Key loss:** option (B) makes password loss fatal to secrets — surface this in the UI; offer re-auth paths for OAuth and re-entry for API keys.
- **Crypto correctness:** unique nonce per encryption, authenticated mode (GCM), constant-time compares, no secrets in logs/error messages (ties back to L1). Add unit tests for round-trip + tamper-detection.
- **Backup feature synergy:** this also protects the RSA key used by the future backup-server upload flow, so the private key is no longer plaintext on disk.

**Scope (touches):** new `SecureVault`; `collection_repository.dart` (encrypt on upsert / decrypt on read); `aichat_models_settings_page.dart` (provider key save/load); `user_repository.dart` + `keys/` handling for `private.pem`; every isolate spawn that carries a collection/token (`embedding_isolate.dart`, `google_file_scanner.dart`, `gmail_scanner_isolate.dart`, `outlook_pst_scanner_isolate.dart`, `new_email_page.dart`, `email_drawer.dart`); one-time migration in `database_manager.dart`. Substantial — implement behind the version flag and test the migration on a populated DB before shipping.

**Open decision before implementation:** master key **(A) Keychain-held** vs **(B) password-derived** (portability vs. recoverability). Everything else follows from that.

---

## Release recommendation

**Ship with known risks — for the current single-user, local-only, trusted-machine deployment.**

**H1 is fixed** (2026-07-10): the local server requires a per-spawn bearer token, so the file endpoints aren't reachable by an arbitrary co-resident process — only by the paired client (or malware that reads the process env). **H2 and M1 are now fixed** (2026-07-22): `/util/thumbnail` reads and `/util/import/pst` writes are confined to the app's own data roots (plus, for thumbnails, the client-declared collection root), and the PST containment check now precedes `makedirs` with a correct separator. The remaining path-read exposure for thumbnails is only the *interim* client-declared-root model, whose full elimination is scheduled with the thumbnail-cache refactor (bytes in, no server-side path). **M3 (double-submit) is fixed.**

The main outstanding blocker before wider/less-trusted distribution is **M2** — third-party OAuth tokens and API keys are still in plaintext SQLite, so a compromise of the DB file (or the client) can still yield account takeover. **M4 accessibility** remains for compliance.
