---
status: proposed
adr: none
remaining: [sample-export, memories-parser, link-download, overlay-handling, import-ui, dedupe]
---

# Plan: Import Snapchat Memories

**Release order: 3.** Memories are the photos and videos users chose to keep in Snapchat. For
many people, years of camera-roll-quality media live only there. This is a **Photos** import
more than a social one. There's urgency too: Snapchat has reportedly moved to charging for
Memories storage beyond 5 GB **(verify)**, so people are looking for a way out.

**Scope:** Memories (photos and videos, with capture date and location). Out of scope: chats,
snaps sent or received, stories viewed, friends, Spotlight. No API exists for Memories, so it's
export only.

## How the export works

- **accounts.snapchat.com › My Data** (or in-app **Settings › My Data**). Tick **Export your
  Memories** (and **Export JSON files**), pick a date range (all time), and submit. Snapchat
  emails when it's ready: hours, up to a few days. Large libraries are split across **several
  zips**.
- **Links expire after about 7 days.** Download promptly.
- Inside: `json/memories_history.json`: an index with, per Memory, the date, the media type,
  **location** (lat/lng when present) and a **download link**. Newer exports may also include a
  `memories/` folder with the files themselves **(verify)**.

## Import

1. **Setup panel** on a "Snapchat" source page: steps above, **Open Snapchat My Data**, then the
   file picker (`.zip`, multiple). Validate it: Snapchat export, how many Memories, the date
   range, whether the media files are included or only links.
2. **Parser:** read `memories_history.json`. For each entry, the media comes from the `memories/`
   folder if present, otherwise from its download link. Historically the link needed an HTTP
   **POST** that returns the real (signed, short-lived) URL **(verify the current behaviour)**.
   Download with a small concurrency limit and retries. Links that have expired are reported:
   "312 Memories need a fresh export".
3. **Rows:** each Memory is a `files` row in a "Snapchat Memories" collection:
   - `date_created` = the Memory's date (not the download date);
   - `latitude`/`longitude` from the index → the map and `near:`;
   - no `social_posts` row (Memories have no caption or audience).
4. **Overlays:** captions and stickers may come as a separate `-overlay.png` next to the main
   file **(verify)**. Default: keep the original and the overlay, linked, and show them
   composited in the viewer. Optionally burn the overlay in on export.
5. **Dedupe:** many Memories are also in the phone's camera roll. Use the same perceptual-hash
   approach as Instagram's camera-roll dedupe (link, don't delete). Re-importing the same export
   is a no-op (`imported_exports` + the file hash).

## Done when

A user imports a multi-zip Memories export. Every Memory appears in Photos at its real date,
with location on the map. Expired links are listed, with a clear "request a new export" path.
Nothing is duplicated on re-import.
