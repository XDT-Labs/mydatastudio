---
status: proposed
adr: none
remaining: [region-hosts, oauth-app, pcloud-api-adapter, diff-cursor, sync-folder-card]
---

# Plan: pCloud

Built on the [shared foundation](files-sources-foundation.md).

## Sync-folder connector

pCloud Drive mounts a virtual drive (`/Volumes/pCloud Drive` or a File Provider folder,
depending on the version) **(verify)**. Treat it like a network volume: metadata scan, with
content read sparingly, since every read streams from pCloud.

## API connector

- **Two regions:** `api.pcloud.com` (US) and `eapi.pcloud.com` (EU), depending on where the user
  registered. The OAuth result returns the right host (`hostname`) **(verify)**. Store it per
  collection.
- **Login:** OAuth 2 (`/oauth2/authorize` → `oauth2_token`). It likely needs a client secret
  **(verify)**, in which case it goes through the token service, as Box does.
- **`PCloudApi` adapter:**
  - full listing `listfolder?recursive=1`;
  - **changes:** the **`diff`** method (an event stream since a `diffid`), with `diffid` stored
    as the cursor **(verify parameters)**;
  - content `getfilelink` → download; thumbnails `getthumblink`;
  - hashes via `checksumfile` (sha1/sha256) when needed for dedupe.
- **pCloud Crypto folder** (client-side encrypted) isn't readable via the API; say so.

## Done when

An EU or US user signs in, the right region is used, and diff-based sync keeps the index
current.
