---
status: proposed
adr: none
remaining: [changes-api, move-to-cloud-file-scanner, scope-decision, sync-folder-option, shared-drives]
---

# Plan: Google Drive

**Today:** `google_file_scanner.dart` (`CloudFileIsolate`) syncs with the Drive API. The
incremental pass is `files.list` with `modifiedTime > <last scan>`. The login is
`LoginProviders.googleDrive` with the full **`drive`** scope, using an OAuth client the user
configures in Settings.

Moves onto the [shared foundation](files-sources-foundation.md) as the `GoogleDriveApi` adapter.

## Work

1. **Switch incremental sync to the Changes API:** `changes.getStartPageToken` once, then
   `changes.list(pageToken, includeRemoved=true, fields=…)`. This catches **deletes, trashing,
   moves and renames** that the `modifiedTime` query misses. Store the token in
   `file_source_sync_state`.
2. **Narrow the scope:**
   - `drive` (read *and write*) isn't needed, because we never write, and Delete in the UI can
     use the provider's web link instead **(decide)**. Prefer **`drive.readonly`**;
   - but `drive.readonly` is still a Google **restricted** scope. Shipping to the public needs
     OAuth verification **plus a yearly CASA assessment**, the same problem as Gmail
     ([email-gmail.md](email-gmail.md)) **(verify)**;
   - **one** verification and assessment covering both Gmail and Drive scopes is cheaper than two.
     Record the decision in both plans.
3. **No-review alternative: the sync folder.** Google's desktop app ("Drive for desktop") mounts
   `~/Library/CloudStorage/GoogleDrive-<account>/` (`My Drive`, `Shared drives`). The
   sync-folder connector indexes it with no OAuth at all. Most files are online-only
   placeholders, so the dataless rules apply. Google Docs/Sheets/Slides appear as `.gdoc`
   shortcut files with no content: index them as links.
4. **Google-native files** (API path): export Docs → `text/plain` / PDF, Sheets → CSV, Slides →
   PDF, through `files.export`, for text extraction only (within the size limit).
5. **Shared drives:** `supportsAllDrives` / `includeItemsFromAllDrives`, and a per-drive cursor
   (`changes.list` with `driveId`).
6. **Content hash:** `md5Checksum` → `files.content_hash` for cross-source dedupe.

## Done when

- Deleting, moving or renaming a file in Drive is reflected on the next sync.
- Users without a verified build can add Drive through the sync folder with no sign-in, and
  online-only files aren't downloaded.
- The verification/CASA decision is recorded, shared with Gmail.
