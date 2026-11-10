---
status: proposed
adr: none
remaining: [photokit-spike, permission-flow, backfill, change-tokens, icloud-originals, albums, live-photos]
---

# Plan: Apple Photos (the macOS Photos library, including iCloud Photos)

## Context

For most Mac users this is where their photos live, and nothing reads it today.
[files-icloud-drive.md](files-icloud-drive.md) calls iCloud **Photos** out of scope: it's the
Photos library, not iCloud Drive. Pointing a file collection at `~/Pictures/Photos Library.photoslibrary`
isn't a fix: the package layout is private, edits are stored as adjustments, and with
"Optimize Mac Storage" most originals are only in iCloud.

Part of the Photos collection type: `photos.apple` ([photos-collection-type.md](photos-collection-type.md)).

## Approach: PhotoKit

Read the library through Apple's **PhotoKit** framework, which is the supported way for a
third-party app. Either the [`photo_manager`](https://pub.dev/packages/photo_manager) Flutter
plugin (it supports macOS) or a small native plugin of our own; the spike decides.

- **Permission:** `NSPhotoLibraryUsageDescription` in `Info.plist`, plus the sandbox entitlement
  `com.apple.security.personal-information.photos-library`. Ask for read access; handle "limited"
  and "denied" with the steps to change it in System Settings.
- **Backfill:** `PHAsset.fetchAssets` for images and videos. Write each asset to `files`:
  capture date (`creationDate`), location, favourite, media subtype (Live Photo, panorama,
  screenshot), dimensions, and the asset's `localIdentifier` as the stable id.
- **Originals and edits:** export the current version for thumbnails and embeddings through
  `PHImageManager` / `PHAssetResourceManager`. Keep the original too only if the content policy
  says so. **iCloud-only originals** need `isNetworkAccessAllowed = true`: the same bounded
  "download for indexing" choice as the sync-folder connector, with a size estimate first.
- **Albums:** `PHAssetCollection` (user albums and shared albums) → `albums` / `album_files`.
  Smart albums aren't copied.
- **Incremental sync:** persistent change tokens (`PHPhotoLibrary.fetchPersistentChanges(since:)`,
  macOS 13+ **(verify)**), stored in `collections.change_cursor`, so inserts, updates and deletes
  arrive without a rescan. Fall back to a full re-list if the token expires.
- **Not available:** people's names from face recognition and Memories aren't in PhotoKit's
  public API **(verify)**. Our own clustering covers faces later.

## Spike (first)

On a real library with iCloud Photos and "Optimize Mac Storage" on: does `photo_manager` give us
persistent change tokens and resource export, or do we need our own plugin? How long do iCloud
original downloads take, and what errors come back offline? Does the sandboxed app get the
permission prompt?

## Done when

A Mac's Photos library, including iCloud-only items, imports as one `photos.apple` collection
with correct capture dates, locations and albums; new, edited and deleted photos sync through
change tokens without a rescan; and nothing in the Photos library is modified.
