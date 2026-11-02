---
status: proposed
adr: none
remaining: [app-registration, pkce-login, dropbox-api-adapter, production-approval, sync-folder-card, provider-ui-actions]
---

# Plan: Dropbox

The `file.dropbox` constant and a commented-out `DropboxProvider` exist today; nothing is
behind them. Built on the [shared foundation](files-sources-foundation.md).

## API connector

- **Register a Dropbox app** (xdtlabs): Scoped access, **Full Dropbox**, scopes
  `account_info.read files.metadata.read files.content.read` (read-only).
- **Login:** OAuth 2 **PKCE** (no client secret in the binary) with a loopback redirect and
  `token_access_type=offline` for a refresh token. Access tokens are short-lived (about 4 hours)
  and refresh silently **(verify)**.
- **`DropboxApi` adapter:**
  - **Full listing:** `files/list_folder` (`recursive=true`, `include_deleted=true`) →
    `list_folder/continue` until `has_more` is false; store the **cursor**;
  - **Changes:** `list_folder/continue` with the stored cursor. It returns `file`, `folder` and
    `deleted` entries, so moves show as a delete plus an add, matched by `id`.
    `files/list_folder/longpoll` can wake the sync instantly (later);
  - **Content:** `files/download` (supports range requests for resume). **Thumbnails:**
    `files/get_thumbnail_batch` (up to 25 per call) for images, so no full download is needed
    for the Photos grid;
  - **Hash:** `content_hash` (Dropbox's block hash) → cross-source dedupe;
  - **Rate limits:** back off on `429` with `Retry-After`.
- **Production approval:** a new app is in **development** status. Once it reaches **50 linked
  users** it has **two weeks** to get production approval, or it stops linking new users (the
  development cap is 500). Apply before the beta reaches 50 testers. The review checks the
  app's purpose and scope use, and read-only scopes help.
- **`DropboxProvider`** (UI actions): list, download, open (web link
  `https://www.dropbox.com/home/<path>`), delete only if we keep a write scope (proposal: no).

## Sync-folder connector

The Dropbox desktop app on modern macOS lives at `~/Library/CloudStorage/Dropbox/` (File
Provider). Older installs use `~/Dropbox`. Detect either and offer **Add**. Online-only files
follow the dataless rules.

## Setup

**Sign in with Dropbox** → choose folders → content estimate → Start. Or **Add** from "Found on
this Mac".

## Done when

A user signs in (no secret involved), and the whole Dropbox is indexed with thumbnails in Photos.
Changes, moves and deletes arrive every 30 minutes. Production approval is granted before user
50.
