---
status: proposed
adr: none
remaining: [identity-resolution, sign-in, list-records-backfill, incremental, blobs, car-backup, ui]
---

# Plan: Sync Bluesky

**Release order: 1.** The easiest service we've planned. The AT Protocol is open: every account's
data lives in a public repository on its PDS (Personal Data Server), readable over plain
HTTP/JSON, free, with no developer app and no approval, worldwide.

**Scope:** the user's own posts (including replies and quote posts) and the images and videos
attached to them. Out of scope: likes, follows, plain reposts, DMs, and other people's posts.

Uses the shared social foundation ([social-x-sync.md](social-x-sync.md), ADR 0002):
`social_posts` with `platform = 'bluesky'`, media in `files`, `SocialPostCard`, the
`ScannerManager` periodic trigger.

## How it works

1. **Resolve the account.** Handle (`mike.bsky.social` or a custom domain) →
   `com.atproto.identity.resolveHandle` → DID (`did:plc:…`) → DID document
   (`https://plc.directory/<did>`, or `/.well-known/did.json` for `did:web`) → the account's
   **PDS endpoint**. Always talk to the user's own PDS. Not everyone is on `bsky.social`.
2. **Sign in (to prove it's you).** The user creates an **app password** (Bluesky **Settings ›
   Privacy and security › App passwords**) and signs in via `com.atproto.server.createSession`
   (handle + app password → `accessJwt` / `refreshJwt`). Posts are public, so reading doesn't
   strictly need auth. But signing in stops someone archiving another person's account, and
   gets better rate limits **(verify)**. Store the refresh token via `CredentialCodec`, and
   refresh with `com.atproto.server.refreshSession`.
3. **Backfill:** `com.atproto.repo.listRecords?repo=<did>&collection=app.bsky.feed.post&limit=100`,
   paging by `cursor`. That's plain JSON, so there's no CBOR parsing. Each record gives `text`,
   `createdAt`, `facets` (links, mentions, hashtags), `reply` (parent/root), `embed` (images,
   video, an external link card, a quoted record) and `langs`. `external_id` = the record's `uri`
   (`at://<did>/app.bsky.feed.post/<rkey>`).
4. **Media (blobs):** `embed.images[].image.ref` is a blob CID. Fetch it with
   `com.atproto.sync.getBlob?did=<did>&cid=<cid>` into `files`, keeping `alt` text as the file
   description. Videos are the same: a blob plus a thumbnail.
5. **Incremental:** daily (or hourly; it's free). `listRecords` returns newest first, so page
   until reaching a stored `uri`. Edits don't exist for posts. Deletes: a missing record is
   detectable by re-listing, but per the archive rule we keep local copies.
6. **Optional full backup:** `com.atproto.sync.getRepo?did=<did>` returns the whole repository
   as a **CAR file**: the same thing as Bluesky's **Settings › Account › Export my data**.
   Store the CAR as-is in the collection folder as a verifiable backup. Parsing it (DAG-CBOR +
   Merkle Search Tree) isn't needed for v1.

No location data exists on Bluesky posts.

## Setup UI

The shared setup panel:
1. "Enter your Bluesky handle" → resolve it, then show the avatar and post count.
2. "Create an app password": steps plus **Open Bluesky settings**. Paste the password.
3. **Start sync**, with progress ("1,204 posts, 380 images").

## Tests

Handle → DID → PDS resolution (`did:plc` and `did:web`, with a custom-domain handle); paging;
facets → linkified text (UTF-8 byte offsets, not UTF-16: verify with an emoji fixture); image,
video, quote and external embeds; incremental stop at a known `uri`; refresh-token expiry.

## Done when

A user anywhere enters a handle and app password, and gets every post with media, plus new posts
daily, at no cost to anyone.

## Open questions

- Require sign-in, or allow archiving by handle alone (public data)? Proposal: require it, so
  the archive is always the user's own.
