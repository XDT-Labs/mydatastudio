---
status: in-progress
adr: none
remaining: [provider-hint, download-for-indexing]
---

# Plan: File sharing sources: shared foundation

Every cloud storage service reaches the app in one of two ways. This plan builds both once,
so each provider plan (table at the end) is a small adapter plus setup text.

1. **API connector:** we call the provider's API (OAuth), list files and changes, and fetch
   content on demand. Used where a usable public API exists: Google Drive, Dropbox, OneDrive,
   Box, pCloud, WebDAV.
2. **Sync-folder connector:** the provider's own desktop app already syncs a folder onto the
   Mac, and we index that folder with the existing local scanner. Used where no usable API
   exists (iCloud Drive, Proton Drive, Sync.com, MEGA), and offered as a no-sign-in alternative
   for the rest.

## Where we are

- `FileSourceRegistry` maps `Collection.scanner` → a `FileSourceProvider` (UI actions: list,
  download, delete, open). Registered: `file.local`, `file.gdrive`. `file.dropbox` and
  `file.onedrive` constants exist with no implementation.
- Background sync is done by `CollectionScanner` isolates: `LocalFileIsolate` and
  `CloudFileIsolate` (Google Drive, `google_file_scanner.dart`).
- Drive's incremental sync queries `modifiedTime > <last scan>`. That **misses deletes, moves out
  of the collection and trashed files**, and the code says so ("we skip cleanup_deleted because
  incremental sync only sees changes").
- `collections.download_local_copy` already toggles full local copies.

## 1. `CloudFileScanner`: one isolate, per-provider adapters

Generalise `CloudFileIsolate` into `CloudFileScanner` (same isolate pattern, `writeViaMain()`
writes, embedding pause), driven by an adapter that only does I/O:

```dart
abstract class CloudFileApi {
  Future<ChangePage> listChanges(String? cursor); // null cursor = full listing
  Future<String> latestCursor();                  // for "start from now"
  Stream<List<int>> download(String fileId, {int? start}); // resumable
  Future<Uint8List?> thumbnail(String fileId);    // server-side thumbnail if offered
  Future<void> refreshAuth();
}
class ChangeItem { String id; String? parentId; String name; String path; bool isFolder;
  bool deleted; int? size; DateTime? modified; String? contentHash; String? mime; }
```

Adapters: `GoogleDriveApi` (moved out of the current isolate), `DropboxApi`, `OneDriveApi`,
`BoxApi`, `PCloudApi`, `WebDavApi`. Each is a pure-Dart class tested against recorded JSON.

## 2. Change-cursor sync (deletes and moves included)

Every API we target has a "changes since cursor" call: Drive `changes.list` (`startPageToken`),
Dropbox `list_folder/continue`, Graph `delta`, Box `events`, pCloud `diff`, WebDAV `PROPFIND`
(comparing ETags; no cursor). Store `(collection_id, cursor, last_full_scan)` in a new
`file_source_sync_state` table.
- **First run:** full listing, then save the cursor.
- **Every run:** apply changes in order. Upsert new and changed items. Moves update
  `parent`/`path`. Deletes follow the collection's **"Keep files deleted in <provider>"**
  setting: mark `is_deleted` (default, archive-style) or remove the row **(decide; match the
  email engine's default)**.
- **Cursor expired or reset** (providers invalidate old cursors): full re-list, matched by
  file id. Re-download nothing that hasn't changed.
- **Schedule:** the `ScannerManager` periodic trigger, default every 30 minutes. Long-poll
  where offered (Dropbox `list_folder/longpoll`) is a later optimisation.

## 3. Content policy: what gets downloaded

Cloud libraries can be terabytes, so metadata is free and content is selective:

| Content | Default | Why |
|---|---|---|
| Metadata (name, path, size, dates, hash, MIME) | Always | Browsing and search by name |
| Thumbnails | Images and videos: the provider's thumbnail endpoint if offered, else download and thumbnail locally (aiserver `/util/thumbnail`) | Photos module |
| Images (full) | On; limit configurable (e.g. ≤ 50 MB each) | Photos, image embeddings, EXIF geo |
| Documents (PDF, Office, text) | Download for text extraction up to a size limit, then discard unless kept | Unified search (document extraction) |
| Video, archives, everything else | Metadata only | Size |
| Full local copy | Off (existing `download_local_copy`) | Offline archive |

The setup screen shows an estimate before the first sync: "18,400 files · 312 GB · we'll
download about 41 GB of photos and documents."

## 4. Sync-folder connector (no API needed)

- **Detect** installed providers by looking for their folders, and show them as one-click cards
  ("We found Dropbox, iCloud Drive and Proton Drive on this Mac"):
  - **`~/Library/CloudStorage/`**: each File Provider–based app (Dropbox, OneDrive, Google
    Drive, Box, Proton Drive, …) mounts a `<Provider>-<account>` folder here;
  - **`~/Library/Mobile Documents/com~apple~CloudDocs`**: iCloud Drive;
  - legacy locations (`~/Dropbox`, `~/MEGA`, `~/Sync`) as configured by those apps.
- **Index with `LocalFileIsolate`**, plus a `providerHint` on the collection (icon, name,
  "Open in Dropbox").
- **Placeholders ("dataless" files):** File Provider and iCloud keep files **online-only** until
  opened. Reading one **downloads it**, so a naïve scan would pull a whole cloud library onto the
  disk. Rules:
  - Detect dataless files with `stat()` / `getattrlist()` and the **`SF_DATALESS`** flag in
    `st_flags` (also reported as `UF_DATALESS`, 0x40000000; **verify against the SDK
    headers**). Dart's `FileStat` doesn't expose `st_flags`, so add a small **FFI `stat` call**
    (or a Swift method channel) in `scanner_path_helper.dart`.
  - Legacy iCloud stubs (`.Name.ext.icloud`) are handled too: show them as the real filename,
    online-only.
  - For dataless files: **index metadata only**. Never open them for thumbnails or text.
  - Optional **"Download online-only files for indexing"** per collection, with a size budget.
    It explicitly triggers materialisation (and can tell the provider to evict them afterwards,
    where supported).
  - The local scanner stops following symlinks out of the sync root.
- **What sync folders can't give us:** sharing info, version history, server-side thumbnails,
  and anything the user excluded with the provider's selective sync. Say so on the card.

## 5. OAuth

- **Public PKCE clients registered by xdtlabs** wherever the provider allows a desktop client
  without a secret (Dropbox: PKCE; Microsoft: PKCE, reusing the Entra app from
  [email-outlook.md](email-outlook.md) with `Files.Read` added). Loopback redirect via
  `DesktopOAuthManager`, after relaxing its "secret required" check per provider.
- Providers that require a client secret (Box, likely pCloud **(verify)**): use the Cloud Run
  token service from [social-facebook-sync.md](social-facebook-sync.md) §Deferred, or a
  "bring your own app" field. Decide per provider.
- **Read-only scopes only.** We never write to the user's storage. Delete actions in the UI stay
  where they exist today, behind confirmation.
- Tokens are stored through `CredentialCodec`, as today.

## 6. Cross-source dedupe

The same photo often lives in Drive, Dropbox and the camera roll. Use the provider's content
hash where available (Drive `md5Checksum`, Dropbox `content_hash`, OneDrive
`quickXorHash`/`sha1Hash`, Box `sha1`), and otherwise our own SHA-256 of downloaded content. Index
it as `files.content_hash`, and let Photos show one item with "Also in Dropbox, Google Drive"
(link, don't delete), the same model as the social camera-roll dedupe.

## 7. Setup UI

On **New file source**, one page:
- **"Found on this Mac":** detected sync folders (section 4), each with **Add**.
- **"Connect an account":** API providers. **Sign in with <provider>**, then choose folders
  (default: everything) and see the content-policy estimate, then **Start sync**.
- **"Other":** WebDAV / Nextcloud server, network share, or any local folder (existing).

## Tests

- Each adapter against recorded change pages: create, modify, move, rename, delete, an expired
  cursor.
- `CloudFileScanner`: interrupted sync resumes from the cursor; moves update paths; deletes
  follow the setting.
- Dataless detection: an FFI unit test on a real File Provider placeholder (manual or CI on
  macOS), and a legacy `.icloud` stub. A dataless file is never opened by the scanner.
- Content policy: a file over the size limit isn't downloaded; the estimate matches the plan.
- Content-hash dedupe across two collections.

## Provider plans

| Provider | Connector | Plan |
|---|---|---|
| Google Drive | API (existing) + sync folder | [files-google-drive.md](files-google-drive.md) |
| Dropbox | API + sync folder | [files-dropbox.md](files-dropbox.md) |
| OneDrive / SharePoint | API + sync folder | [files-onedrive.md](files-onedrive.md) |
| iCloud Drive | Sync folder only | [files-icloud-drive.md](files-icloud-drive.md) |
| Box | API + sync folder (Box Drive) | [files-box.md](files-box.md) |
| pCloud | API + sync folder (pCloud Drive) | [files-pcloud.md](files-pcloud.md) |
| Proton Drive | Sync folder (SDK not ready for third parties) | [files-proton-drive.md](files-proton-drive.md) |
| MEGA | Sync folder (MEGAcmd later) | [files-mega.md](files-mega.md) |
| Sync.com | Sync folder only | [files-sync-com.md](files-sync-com.md) |
| Google Photos | Takeout only (the Library API no longer reads user libraries) | [files-google-photos.md](files-google-photos.md) |
| WebDAV: Nextcloud, ownCloud, Synology, NAS; SMB shares | API (WebDAV) or mounted volume | [files-webdav-nas.md](files-webdav-nas.md) |

**Not supported:** Amazon Photos and Amazon Drive (Amazon shut down the Drive API, and Photos has
no public API: users can download from the Amazon Photos app and index the folder).
