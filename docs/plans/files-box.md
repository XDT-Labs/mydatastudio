---
status: proposed
adr: none
remaining: [secret-decision, box-api-adapter, events-cursor, sync-folder-card]
---

# Plan: Box

Built on the [shared foundation](files-sources-foundation.md). Box is common in work settings,
and many users already have **Box Drive**, so the sync folder comes first and the API second.

## Sync-folder connector (first)

Box Drive mounts `~/Library/CloudStorage/Box-Box/` (File Provider) **(verify the folder
name)**. Online-only files follow the dataless rules. No sign-in.

## API connector

- **App:** a Box **OAuth 2.0** app (a free developer account; the Developer Console). Box's
  token exchange takes a **client secret** alongside the redirect URI, and PKCE support is
  unconfirmed **(verify)**. If a secret is required, the exchange and refresh go through the
  **Cloud Run token service** (a `/box/exchange` endpoint), and no secret ships in the app.
  Box allows **loopback redirects on any port**, which fits `DesktopOAuthManager`.
- **Scope:** read-only ("Read all files and folders").
- **`BoxApi` adapter:**
  - full listing: `GET /folders/{id}/items` (paged, `fields=` for size, sha1, modified_at, path);
  - **changes:** the **Events API** (`GET /events?stream_type=changes&stream_position=<cursor>`),
    storing `next_stream_position` (long-poll is available later **(verify)**);
  - content `GET /files/{id}/content`, thumbnails via representations (`x-rep-hints`);
  - `sha1` → dedupe.
- **Enterprise:** admins may restrict third-party apps, so detect and explain.

## Done when

A Box Drive user adds the folder in one click. An API user signs in without a secret in the
binary and gets event-driven incremental sync.
