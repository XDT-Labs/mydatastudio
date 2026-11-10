---
status: proposed
adr: none
remaining: [P0-type, P1-add-page, P2-drawer, P3-move-sources, export-folder-cards]
---

# Plan: the Photos collection type

## Context

Today there are two collection types in code: `file` and `email`
([new_file_collection_page.dart](../../client/lib/modules/files/pages/new_file_collection_page.dart),
`AppConstants.scanner*`). The Photos screen shows the images and videos found in **file**
collections; it has no sources of its own. The photo services in the plans were therefore filed
under Files (Google Photos) or Social (Flickr), and Apple Photos had no plan at all.

Photo services aren't folders of files. They bring albums, capture dates and places that live
outside EXIF, edited and original versions, Live Photos, and favourites, and the user thinks of
them as "my photo library", not as a drive. They get a collection type of their own, the way
[app-calendar.md](app-calendar.md) §5.2 adds `calendar`.

## Scope

- **`collections.type = 'photos'`**, with scanner constants in `AppConstants` next to the file and
  email ones: `photos.apple`, `photos.google_takeout`, `photos.flickr`, `photos.smugmug`,
  `photos.immich`, `photos.photoprism`, `photos.synology`, and `photos.folder` (an exported
  library folder, see below).
- **The rows still go in `files`** (plus `albums` / `album_files`). Every photo feature that
  exists today (the gallery, clustering, places, embeddings, unified search, the map) reads
  `files`, so it works for photo collections with no change. The type decides where the
  collection is **added, listed and managed**, not where its rows live.
- **Out of scope:** a separate photos table; writing back to any service; the Photo Editor
  ([app-photo-editor.md](app-photo-editor.md)) and Timeline ([app-timeline.md](app-timeline.md))
  apps, which simply see more photos.

## Design

- **Adding sources: `/photos/add` → `NewPhotosSourcePage`**, built like `NewEmailPage`: one tab
  or tile per source, each arriving with its own plan. The Photos drawer gets an **Add photo
  library** button.
- **Drawer:** the Photos drawer lists each photo collection as a `DrawerSection` (Sync now,
  Settings, Remove), above the file collections that contain photos.
- **Files screen:** photo collections don't appear in the Files drawer, so a photo library isn't
  listed twice. Their files still show up in search results with their collection name.
- **Rail:** Photos moves to the `collections` group next to Files, Email and Social.
- **Sync machinery is reused unchanged:** `ScannerManager` registration, `needs_re_auth`, sync
  status, the periodic trigger, the change cursor (`collections.change_cursor`), the content
  policy, and the camera-roll dedupe (`files.duplicate_of`, link, don't delete) from Wave 4.
- **Export-folder cards** for services with no API (Amazon Photos, Ente, Shutterfly): a
  `photos.folder` collection pointed at the folder the service's own app or export writes to,
  with the steps to get that export. It's a local file scan, labelled with the service.

## Phases

- **P0 – Type:** the `photos` type and scanner constants; `ScannerManager` accepts photo
  collections; a migration leaves every existing collection as `file`.
- **P1 – Add page:** `/photos/add` with the export-folder card as its first source.
- **P2 – Drawer and rail:** Photos drawer sections, the Add button, Files drawer filtering.
- **P3 – Move the planned sources:** Google Photos ([files-google-photos.md](files-google-photos.md))
  and Flickr ([social-flickr-archive.md](social-flickr-archive.md)) create `photos` collections
  instead of `file` and social ones.

## Open questions

- Should a local folder the user already indexes as a file collection be convertible to a photo
  collection without a rescan? (Leaning: yes, by changing `type`; the rows don't move.)

## Done when

- A `photos` collection can be added from `/photos/add`, syncs through `ScannerManager`, appears
  in the Photos drawer and not the Files drawer, and its photos appear in the gallery, map,
  clustering and search exactly as file-collection photos do.
- Existing file collections are unchanged after the migration.
- Google Photos and Flickr create `photos` collections.
