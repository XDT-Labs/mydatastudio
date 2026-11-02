---
status: proposed
adr: none
remaining: [takeout-steps, takeout-photos-parser, json-sidecar-merge, scheduled-takeout, dedupe]
---

# Plan: Google Photos (via Takeout)

**The API route is closed.** Since **31 March 2025** the Google Photos **Library API** can only
list, search and read **media the app itself created**. The `photoslibrary.readonly` scope was
removed. The replacement **Picker API** makes the user pick items by hand each session, which
doesn't work for backing up a whole library. So Google Photos is a **Takeout import**, reusing the
Takeout handling from [email-file-imports.md](email-file-imports.md) and
[social-youtube-archive.md](social-youtube-archive.md).

## The export

- **takeout.google.com › Deselect all › Google Photos** (all albums, or choose) → **.zip** (or
  .tgz), **50 GB** parts → **Export once**, or **every 2 months for 1 year**, delivered by
  download link or **Add to Drive** **(verify the scheduling options)**. Large libraries arrive as
  many parts.
- Layout **(verify)**: `Takeout/Google Photos/<album or "Photos from YYYY">/` holding the media
  files, each with a **JSON sidecar** (`IMG_1234.jpg.json` / `.supplemental-metadata.json`)
  carrying `photoTakenTime`, `geoData` / `geoDataExif`, `description`, `people`, and the
  original URL.

## Import

1. **Setup panel:** Takeout steps, **Open Google Takeout**, and a picker for one or more zips
   (or a folder of extracted parts). Validate it: Google Photos Takeout, the item count, the date
   range, the parts present.
2. **Parser:**
   - stream each zip;
   - for each media file, find its sidecar. Name matching is notoriously messy: truncated names
     (47 characters), `(1)` duplicates, edited `-edited` variants. Port the known rules
     **(verify against a real export)**;
   - merge the sidecar into the `files` row: `date_created` = `photoTakenTime` (Takeout files
     often have the export date as their mtime), `latitude`/`longitude` from `geoData`,
     `description`;
   - **don't rewrite the image file**.
3. **Albums:** album folders → `albums`. The year folders ("Photos from 2019") aren't albums.
4. **Scheduled:** if the user schedules Takeout to Drive, the Drive connector hands
   `takeout-*.zip` files to this importer (the Drive handoff from the social plans).
5. **Dedupe:** content hash plus perceptual match against the camera roll and other sources. Link,
   don't delete.

## Done when

A multi-part Google Photos Takeout imports with correct capture dates and locations from the
sidecars, albums intact, and no duplicates against the camera roll or a re-import.
