---
status: in-progress
adr: none
remaining: [scope-decision, shared-drives]
---

# Plan: Google Drive

**Today:** `GoogleDriveFileApi` plugs Drive API v3 into the shared `CloudFileScanner`
([foundation](files-sources-foundation.md)). The first sync walks My Drive folder by folder
with `files.list`; every later sync reads `changes.list` from the token stored in
`collections.change_cursor`. The login is `LoginProviders.googleDrive` with the full **`drive`**
scope, using an OAuth client the user configures in Settings. Items 1, 4 and 6 below are built
(#40); 2 and 5 are not.

## Work

1. **Built (#40). Incremental sync through the Changes API:** `changes.getStartPageToken`
   once, then `changes.list(pageToken, includeRemoved=true, fields=…)`. This catches
   **deletes, trashing, moves and renames**. The token is stored in
   `collections.change_cursor`; an expired token falls back to a full re-list.
2. **Narrow the scope:**
   - `drive` (read *and write*) is only needed by the photos batch action that moves a file to
     the Drive trash (`GoogleDriveProvider.deleteFile`). Drop or hide it for Drive, or send
     the user to the provider's web link instead **(decide)**. Prefer **`drive.readonly`**;
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
4. **Built (#40). Google-native files** (API path): `FileBytesLoader` exports Docs → DOCX,
   Sheets → XLSX, Slides → PPTX through `files.export`, which the chunker reads natively with
   their structure. Forms, Drawings, Sites and Shortcuts have no useful export and are skipped.
5. **Shared drives:** `supportsAllDrives` / `includeItemsFromAllDrives`, and a per-drive cursor
   (`changes.list` with `driveId`), since `collections.change_cursor` holds only one. The
   pre-sync estimate (`'me' in owners`) also leaves out files shared with the user.
6. **Built (#40). Content hash:** `sha256Checksum` → `files.content_hash` for cross-source
   dedupe.

## Done when

- Deleting, moving or renaming a file in Drive is reflected on the next sync.
- Users without a verified build can add Drive through the sync folder with no sign-in, and
  online-only files are indexed without staying downloaded.
- The verification/CASA decision is recorded, shared with Gmail.
