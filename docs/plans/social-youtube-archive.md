---
status: proposed
adr: none
remaining: [takeout-spike, takeout-import, scheduled-takeout, size-controls, data-api-deferred, ui]
---

# Plan: Archive YouTube uploads via Google Takeout

**Release order: 4.** The videos a user uploaded, private and unlisted ones included, with
their metadata and playlists, from **Google Takeout**. The Gmail plan already uses Takeout, and
Takeout can deliver to **Google Drive on a schedule**, so it reuses the Meta plans' Drive handoff.

**Scope:** the user's own uploads (public, unlisted and private), their titles and
descriptions, and the user's playlists. Out of scope: watch and search history,
subscriptions, likes, comments (they're on others' videos), and live chat.

## The export

- **takeout.google.com › Deselect all › YouTube and YouTube Music** › **All YouTube data
  included** → keep **videos**, **video metadata**, **playlists**, **channels**; untick history,
  subscriptions, comments, live chat. Choose **.zip**, a part size (50 GB max), and **Export
  once** or **Export every 2 months for 1 year** **(verify)**. Delivery: download link, or
  **Add to Drive**.
- Downloads expire after **7 days**, with a cap on the number of downloads **(verify)**.
- Uploaded videos come in their original format or MP4. Metadata comes as CSV/JSON. Google's
  Data Portability schema lists a videos CSV with the video id and duration. Whether titles and
  descriptions are included is disputed by third-party guides **(spike: verify on a real
  export)**.

## Import

1. **Setup panel** (the shared pattern): Takeout steps, **Open Google Takeout**, and the file
   picker for one or more zips. Or, once scheduled to Drive, the Drive scanner hands Takeout
   zips (by name pattern `takeout-*.zip`) to the importer.
2. **Size controls:** videos are big. Before importing, show "38 videos · 64 GB" and offer
   **Import videos** / **Metadata only (link to YouTube)**. Respect the collection's
   `download_local_copy` setting.
3. **Rows:**
   - each upload → a `social_posts` row (`platform = 'youtube'`, `kind = video`, title in
     `link_title`, description in `text`, `created_at` = the publish date, `url` =
     `youtube.com/watch?v=<id>`) linked to its video file in `files`;
   - playlists → `albums`;
   - `external_id` = the video id, which also matches the Data API if that's ever added.
4. **Search and embeddings:** title + description embedded. Video frames are embedded and
   described by the existing `EmbeddingIsolate` (as for other videos). Transcripts aren't in
   Takeout, so they're a later idea (local Whisper in aiserver?).

## Deferred: YouTube Data API

`youtube.readonly` lets an app read the user's uploads via their channel's uploads playlist
(`playlistItems.list` is cheap against the default 10,000 units/day quota). But it doesn't
provide the video *file*, only metadata, and it's a Google **sensitive** scope needing OAuth
verification **(verify whether it's sensitive or restricted)**. Revisit only for faster
metadata freshness.

## Done when

A creator imports their Takeout (or schedules it to Drive) and gets every upload, private ones
included, as playable local videos (or metadata only, by choice), searchable by title and
description, with playlists as albums.
