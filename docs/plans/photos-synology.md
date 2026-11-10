---
status: proposed
adr: none
remaining: [api-spike, sign-in, sync, albums, shared-space]
---

# Plan: Synology Photos

## Context

Synology Photos is the photo app on Synology NAS drives. The WebDAV/NAS plan
([files-webdav-nas.md](files-webdav-nas.md)) can index its `/photo` and `/homes/<user>/Photos`
folders, but that loses the albums, the Personal/Shared Space split and the app's metadata.

Part of the Photos collection type: `photos.synology`
([photos-collection-type.md](photos-collection-type.md)).

## Approach

- **API:** the DSM web API (`SYNO.API.Auth`, then the `SYNO.Foto.*` / `SYNO.FotoTeam.*` APIs
  used by the Synology Photos web app). They're **not officially documented (verify)**, so a
  spike checks what's stable across DSM 7.x versions before we commit.
- **Sign-in:** the DSM address and the user's account, with 2-factor support; a session id and
  device token stored like other tokens. Pinned self-signed certificates, as in the WebDAV plan.
- **Sync:** list items in Personal Space and (optionally) Shared Space with capture date,
  location and album membership; download originals or thumbnails by content policy; compare
  modified times for changes.
- **Fallback:** if the API is too unstable, the card points the user at the WebDAV/NAS connector
  for the photo folders, and albums are dropped.

## Done when

A Synology Photos library imports as a `photos` collection with capture dates, locations and
albums from both spaces; changes sync on the next run; and nothing on the NAS is modified.
