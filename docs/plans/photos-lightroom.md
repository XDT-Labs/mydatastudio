---
status: parked
adr: none
remaining: [partner-access, sign-in, sync, albums]
---

# Plan: Adobe Lightroom (cloud)

**Parked:** Adobe's Lightroom API is only open to approved partners **(verify the current
program)**. Nothing is built until Adobe grants access.

## Context

Lightroom (the cloud version, not Lightroom Classic) stores originals and edits in Adobe's
cloud. Lightroom Classic catalogs are local folders plus a `.lrcat` SQLite file, so a file
collection already indexes those photos (without the catalog's keywords and collections).

Part of the Photos collection type: `photos.lightroom`
([photos-collection-type.md](photos-collection-type.md)).

## If access is granted

- **Sign-in:** Adobe IMS OAuth with the Lightroom read scope.
- **Sync:** the catalog's assets with capture date, location, keywords and ratings; download the
  original or a rendition by content policy; albums → `albums` / `album_files`; changes by the
  API's `updated_since` paging **(verify)**.

## Until then

The `/photos/add` card explains how to export originals from Lightroom to a folder and adds it as
an export-folder collection ([photos-collection-type.md](photos-collection-type.md)).

## Done when

The partner-access question is answered. If granted: a Lightroom cloud library imports as a
`photos` collection with originals, capture dates, keywords and albums, and changes sync.
