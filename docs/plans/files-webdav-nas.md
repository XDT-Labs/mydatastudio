---
status: proposed
adr: none
remaining: [webdav-adapter, nextcloud-login-flow, etag-sync, mounted-volume-support, offline-volume-handling]
---

# Plan: Nextcloud, ownCloud, Synology and other WebDAV servers; network shares (SMB/NAS)

For self-hosted and home storage. Built on the [shared foundation](files-sources-foundation.md).

## WebDAV (API connector)

- **Covers:** Nextcloud, ownCloud, Synology (WebDAV Server package), QNAP, Seafile (WebDAV),
  Hetzner Storage Box, and any WebDAV endpoint.
- **Login:**
  - **Nextcloud/ownCloud:** **Login Flow v2**. POST `/index.php/login/v2`, open the returned
    URL in the browser, poll for an **app password**, so the user never types their real
    password into our app **(verify for ownCloud)**;
  - generic WebDAV: URL + username + password (or an app password), stored via `CredentialCodec`.
- **`WebDavApi` adapter:**
  - listing: `PROPFIND` with `Depth: 1`, walking the tree (some servers refuse `infinity`),
    requesting `getetag`, `getlastmodified`, `getcontentlength`, `resourcetype` and, on
    Nextcloud, `oc:fileid` / `oc:checksums`;
  - **changes:** WebDAV has no change feed, so compare the **folder ETag** (it changes when
    anything below changes on Nextcloud and ownCloud **(verify)**), descending only into changed
    folders. Generic servers get a full walk on a slower schedule;
  - content `GET` with `Range`; Nextcloud previews via `/index.php/core/preview?fileId=…`.
- **TLS:** home servers often use self-signed certificates. Allow a **per-server pinned
  certificate** after explicit confirmation, never a global "ignore certificate errors".

## Network shares (SMB / AFP / NFS)

- The user mounts the share in Finder (`smb://nas.local/photos`). It appears under `/Volumes/`.
  Add it as a **local collection** with `providerHint = network`.
- **Offline volumes:** when the share isn't mounted, don't treat its files as deleted. Mark the
  collection "Offline — connect to <share>" and skip the scan. Store the volume UUID to tell the
  same share apart from a different one mounted at the same path.
- **Performance:** reads go over the network, so use metadata-first scanning, with content reads
  under the foundation's content policy and lower concurrency.
- The same offline rule applies to **external drives**, which the local scanner already
  supports, so this fixes both.

## Done when

- A Nextcloud user connects through Login Flow v2 (no password typed into our app), and syncs
  via ETag comparison.
- A Synology WebDAV share with a self-signed certificate connects after pinning.
- An SMB share or external drive that's unplugged shows as offline, not deleted, and resumes when
  it's back.
