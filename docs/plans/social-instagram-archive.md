---
status: proposed
adr: none
remaining: [sample-export, parser, import-isolate, ui]
---

# Plan: Import an Instagram archive

`client/lib/modules/social/pages/instagram_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Instagram" button.

This plan replaces it with a **one-time import** of the user's Instagram export (Accounts
Center › Your information and permissions › Download your information), requested in **JSON**
format.

## Why archive import, not the API

Meta shut down the Instagram Basic Display API, which was the only way for a personal account to
read its own media. What remains (the Instagram Graph API) is for business and creator accounts.
**Verify this is still true before building.**

## Depends on

The **shared social foundation** in [social-twitter-archive.md](social-twitter-archive.md):
`social_posts` schema, media in `files`, PST-style import isolate, idempotent upsert, search and
LLM-tool integration.

## Instagram-specific work

Instagram is media-first, so most of the value lands in the **Photos module**. The posts table
mostly holds captions and dates.

1. **Sample export first.** Record a real, recent layout before writing the parser. Known shape
   (verify):
   - `your_instagram_activity/content/posts_1.json`, `stories.json`, `reels.json`;
   - media under `media/posts/<YYYYMM>/…`, `media/stories/…`;
   - `creation_timestamp` in Unix seconds;
   - some media entries carry `media_metadata.photo_metadata.exif_data` with latitude and
     longitude, even though the image file itself has its EXIF stripped.
   
   Commit a small trimmed fixture.
2. **Text decoding:** same Latin-1-escaped UTF-8 problem as Facebook (same exporter). Share the
   decoding helper rather than copying it.
3. **Parser** (pure Dart):
   - **Posts:** one post with many media items (carousels) maps to one `social_posts` row
     linked to N `files` rows.
   - **Stories:** imported as `kind = story`.
   - **Reels:** videos.
   - **Metadata:** caption, plus any `exif_data` coordinates and timestamps written onto the
     `files` rows, so photos sort by real date and work with `near:` and the map view.
4. **Import isolate, UI, embeddings:**
   - same as the shared foundation;
   - images get descriptions, image embeddings and clustering for free, since they're in `files`;
   - `instagram_page.dart` becomes a grid of posts with captions and search.

## Open questions

- Import DMs (`messages/inbox/…`)? Same privacy question as the other platforms; default off.
- Instagram re-encodes images when exporting. Should we dedupe against the same photo already
  imported from the camera roll or Google Drive (perceptual hash or embedding similarity), or
  show both?
- Archived and deleted posts: include them, and mark them?

## Done when

- Importing a real export creates one post per Instagram post, with carousel media all linked,
  and correctly decoded captions. Re-importing changes nothing.
- Every photo and video from the export appears in Photos with the post's date (not the export
  date), and with location when the export provides it.
- A known caption is found by keyword search and `type:social`. A photo is found by a semantic
  query once its embedding is built.
- Tests: carousel mapping, `exif_data` extraction, caption decoding, and import idempotency.
