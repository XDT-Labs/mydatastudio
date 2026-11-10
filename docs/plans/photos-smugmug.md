---
status: proposed
adr: none
remaining: [api-key-setup, oauth1-signing, backfill, incremental, albums]
---

# Plan: SmugMug

## Context

SmugMug holds original-quality photos for photographers and long-time users (it also owns
Flickr). Its API v2 uses **OAuth 1.0a**, so it reuses the signer built for X in Wave 4 and
shared with Flickr ([social-flickr-archive.md](social-flickr-archive.md), [social-x-sync.md](social-x-sync.md)).

Part of the Photos collection type: `photos.smugmug`
([photos-collection-type.md](photos-collection-type.md)).

## Approach

- **Sign-in:** bring your own API key, like Flickr: the user applies for a key at SmugMug's
  developer site **(verify the current terms)**, then authorises it for read access with a
  loopback callback.
- **Backfill:** walk the user's node tree (folders → albums → images) with the image metadata
  (capture date, title, caption, keywords, geo) and download the archived original
  (`ArchivedUri`) or a large size, by content policy.
- **Albums:** SmugMug albums → `albums` / `album_files`; folders become album name prefixes.
- **Incremental:** daily; compare album and image `LastUpdated` dates.

## Done when

A SmugMug account imports as a `photos` collection with originals, capture dates, geo and
albums; new and changed photos sync daily; and nothing on SmugMug is modified.
