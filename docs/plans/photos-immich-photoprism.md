---
status: proposed
adr: none
remaining: [immich-api-key, immich-sync, photoprism-app-password, photoprism-sync, albums, dedupe]
---

# Plan: Immich and PhotoPrism (self-hosted photo servers)

## Context

Immich and PhotoPrism are the most common self-hosted photo libraries, often running on the same
NAS the WebDAV plan ([files-webdav-nas.md](files-webdav-nas.md)) and the NAS container
([core-nas-docker.md](core-nas-docker.md)) target. Indexing their storage folder over WebDAV or
SMB works, but loses albums, edits, people and the server's own metadata. Both have REST APIs.

Part of the Photos collection type: `photos.immich` and `photos.photoprism`
([photos-collection-type.md](photos-collection-type.md)).

## Immich

- **Sign-in:** the server URL plus a user-created **API key** (Account Settings › API Keys),
  with read-only permissions where the server version supports them **(verify)**. Pinned
  self-signed certificates, as in the WebDAV plan.
- **Sync:** page through the user's assets with their metadata (capture date, EXIF, location,
  favourite, archived). Use the server's incremental sync endpoints for changes and deletes if
  the version supports them **(verify the current API)**, otherwise compare `updatedAt`.
- **Media:** download originals or the server's preview, by content policy.
- **Albums:** the user's albums → `albums` / `album_files`.

## PhotoPrism

- **Sign-in:** the server URL plus an **app password** (Settings › Account › Apps and Devices)
  **(verify)**.
- **Sync:** the photos search API paged by `updated` date; albums → `albums`; originals or
  thumbnails by content policy.

## Shared

- Both are a `CloudFileApi`-style adapter on the shared cloud scanner, polling on the periodic
  trigger.
- Dedupe against the same photos indexed from the NAS share or the camera roll (content hash,
  then the Wave 4 camera-roll dedupe).

## Done when

An Immich and a PhotoPrism library each import as a `photos` collection with capture dates,
locations and albums; new and deleted photos sync on the next run; a self-signed server works
after the user pins its certificate; and nothing on the server is modified.
