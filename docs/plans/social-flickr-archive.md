---
status: proposed
adr: none
remaining: [api-key-setup, oauth1-signing, backfill, incremental, albums, export-import, ui]
---

# Plan: Archive Flickr

**Collection type:** a `photos` collection (`photos.flickr`), not a social one; see
[photos-collection-type.md](photos-collection-type.md). Built in Wave 5 of the release plan.

**Release order: 3** (with Snapchat). Flickr holds **original-quality photos with EXIF and
geotags**, often a decade or more of them, which makes it a high-value Photos source. Two paths:
the user's own API key (true sync, like X but free), and the account data export.

**Scope:** the user's own photos and videos, with titles, descriptions, tags, albums and
geotags. Out of scope: faves, comments, groups, contacts.

Shared pieces: the setup panel, the file picker, `imported_exports`, the OAuth 1.0a signer from
[social-x-sync.md](social-x-sync.md) (Flickr also uses OAuth 1.0a), and the photo dedupe from
the Instagram plan. Photos go straight into `files` and `albums`; `social_posts` holds a row
only when a photo has a title or description worth searching as a post.

## Path 1: bring your own API key (sync)

- The user requests a free **non-commercial API key** at flickr.com/services/apps/create
  (key + secret), then authorises it for their account (OAuth 1.0a with `perms=read`, loopback
  callback). That gives an access token and secret that don't expire **(verify)**. Free for
  personal use, with no approval and no charges **(verify the current key terms)**.
- **Backfill:** `flickr.people.getPhotos` (`user_id=me`), `per_page=500`, with
  `extras=description,date_upload,date_taken,original_format,geo,tags,url_o,media`. Download
  `url_o` (the original), or use `flickr.photos.getSizes` for videos. Write title, description,
  tags, `date_taken` and lat/lng onto `files`.
- **Albums:** `flickr.photosets.getList` + `getPhotos` → `albums` / `album_files`.
- **Incremental:** daily, `min_upload_date=<newest stored>`. Daily `flickr.photos.recentlyUpdated`
  catches edited titles, tags and geo.
- **Rate limit:** about 3,600 calls/hour per key **(verify)**. Plenty, since the downloads
  themselves aren't API calls.
- **Free-account note:** free Flickr accounts are capped at 1,000 photos. Larger libraries are
  Pro, and the API still sees everything the user owns.

## Path 2: account data export

**Settings › Your Flickr Data › Request my Flickr data.** It takes hours to weeks, the links
expire, and it contains zips of originals plus JSON metadata. Flickr says files keep their EXIF
from upload, while edits made on Flickr (title, description, tags, location) are in the
**separate JSON**. The importer merges the JSON onto each file row (it doesn't rewrite the
image files), matching by photo id in the filename **(verify the naming)**. Rows share
`external_id` = the Flickr photo id with the API path, so the two merge.

## Done when

A user pastes a key, authorises, and gets every original with metadata, albums and geotags in
Photos, with new uploads and edits daily. Or they import the data export with the JSON
metadata applied. No duplicates either way, or against camera-roll copies.
