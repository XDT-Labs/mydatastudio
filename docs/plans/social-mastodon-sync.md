---
status: proposed
adr: none
remaining: [instance-discovery, oauth-dynamic-registration, token-paste-fallback, backfill, incremental, edits, media, archive-import, ui]
---

# Plan: Sync Mastodon (and compatible fediverse servers)

**Release order: 1** (alongside Bluesky). An open, documented REST API on every server, free,
with no central approval. Each user signs in to their own server.

**Scope:** the user's own statuses (posts and replies), including edits and media. Out of scope:
boosts (reblogs), favourites, bookmarks, follows, **direct messages** (visibility `direct`), and
other people's posts.

Uses the shared social foundation ([social-x-sync.md](social-x-sync.md), ADR 0002):
`platform = 'mastodon'`.

## Auth: sign in with your server

1. The user enters their address (`@mike@mastodon.social`) or server (`mastodon.social`).
2. **Register an app on that server at runtime:** `POST /api/v1/apps` with `client_name=My
   Data Studio`, `redirect_uris=http://127.0.0.1:<port>/callback` (or
   `urn:ietf:wg:oauth:2.0:oob`) and `scopes=read:statuses profile`. Each server returns its own
   `client_id` / `client_secret`. Nothing is shipped in the binary, so there's nothing to leak.
   Cache them per server.
3. Authorization-code flow in the browser (with PKCE where the server supports it: Mastodon
   4.3+ **(verify)**) via the existing loopback `DesktopOAuthManager`, then exchange the code.
   Mastodon access tokens don't expire unless revoked **(verify)**.
4. **Fallback:** paste a token created in **Preferences › Development › New application** with
   the `read:statuses` scope. Useful for servers with registration quirks.

Store tokens via `CredentialCodec`.

## Sync

- **Identify:** `GET /api/v1/accounts/verify_credentials` gives the account id, `statuses_count`
  and avatar.
- **Backfill:** `GET /api/v1/accounts/:id/statuses?exclude_reblogs=true&limit=40`, paging with
  `max_id` back to the first post. For the owner's token this includes private
  (followers-only) posts. Skip `visibility == direct`. `external_id` = the status `uri` (stable
  across servers); also store `url`.
- **Content:** `content` is HTML. Convert it to text with `html_text_extractor.dart`, and keep
  the HTML in `raw_json` for rendering. `spoiler_text` (content warning) is stored and shown as a
  collapsed CW. `media_attachments[]` → download `url` (the original) into `files`, with
  `description` as alt text. `poll`, `card` (link preview), `in_reply_to_id`, `language`.
- **Incremental:** every few hours (it's free), `min_id=<newest stored>`.
- **Edits:** `edited_at` is set on edited posts. Re-fetch the last 30 days daily and upsert;
  history is available at `GET /api/v1/statuses/:id/history` if wanted.
- **Rate limits:** default 300 requests per 5 minutes per account **(verify per server)**. Honour
  the `X-RateLimit-*` headers.
- **Moved accounts:** if the user migrated servers, old posts stay on the old server. Offer
  "Add another server" so both archives merge in one Mastodon view.

## Archive import (optional)

**Preferences › Import and export › Request your archive** emails a zip with `outbox.json`
(ActivityStreams 2.0; your `Create` activities are your posts), `actor.json` and a media folder.
Useful when the old server is gone, or the user has left Mastodon. Parse `Create` / `Note`
objects into the same rows; the identity is the object `id` (= the status `uri`), so it merges
with API rows.

## Compatible servers

Pleroma/Akkoma and GoToSocial implement the Mastodon client API, mostly **(verify)**. Misskey
and Firefish don't (they have their own API); they're out of scope for v1.

## Done when

A user on any Mastodon server signs in through their server and gets every post (public,
unlisted, followers-only), with media, content warnings and edits, plus new posts every few
hours. An old-server archive zip merges without duplicates.
