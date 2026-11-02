---
status: proposed
adr: none
remaining: [scheduled-export-spike, sample-export, export-parser, import-isolate, setup-import-ui, drive-handoff, downloads-watcher, schedule-lifecycle, media, embeddings, search, grid-ui]
---

# Plan: Keep an Instagram archive in sync with scheduled exports

`client/lib/modules/social/pages/instagram_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Instagram" button.

This plan replaces it with an Instagram archive that **stays up to date by itself**. The user
sets up a **scheduled JSON export** in Meta's Export Your Information (EYI) tool, delivered to
their Google Drive. Meta then sends a fresh export every day for up to three years. We pick each
one up and merge it into the local archive. It works for **every account type, personal
included**, and needs no Instagram App Review.

**Scope: an archive of what the user posted, not an Instagram client.** That means the user's
own feed posts, carousels, reels and stories, with their captions and any location metadata.
Out of scope: DMs, other people's posts and comments, comments the user left elsewhere, likes,
followers and engagement counts. If the user didn't post it, we don't import it.

> Facts below were checked against Meta's docs on 2026-10-25. Items marked **(verify)** need a
> test against a real account. The spike below exists to answer them.

## Why export-first, and API later (maybe never)

The Instagram API (Instagram Login) only serves **professional accounts** (business or creator).
Meta shut down the Basic Display API that personal accounts used. We can't assume everyday users
will convert their accounts, so the API can't be the main path. The export:
- works for **every account**;
- includes things the API never returns:
  - **location** (`exif_data` coordinates);
  - **expired stories** (when the user's story archive is on, which is the default);
  - **reels with licensed audio** (the API withholds their `media_url`, even from the owner);
- can be **scheduled**, so it covers ongoing sync too, not just backfill;
- needs no App Review, no OAuth with Instagram, and no token service endpoint. Meta delivers
  the files to the user's own Drive.

API sync is **deferred** (see the end). Build it only if real users need something the export
can't give them.

## Setup and import UI (on the Instagram page)

`instagram_page.dart` shows this until the first import finishes. After that, it lives in a
"Sync settings" panel. It's the same `MetaExportSetupPanel` widget as the Facebook page
([social-facebook-sync.md](social-facebook-sync.md)), parameterised for Instagram. Whichever
plan is built first builds it.

**1. "Export your Instagram data": step-by-step instructions**, numbered, with Meta's UI words in
bold:
1. Click **Open Instagram export page**. This opens the EYI deep link in the user's browser,
   pre-filled for a one-time full export to their device:
   `https://accountscenter.instagram.com/info_and_permissions/dyi?source=external&account_type=1&format=JSON&date_range=ALL_TIME&quality=HIGH&locale_override=en_US&sections[0]=IG_YOUR_ACTIVITY`
   **(verify which `import_service` value means "to device")**. Recommend doing this in a
   desktop browser, not the phone app, so the zip lands on this computer.
2. If you're asked to log in, use your Instagram account. If anything isn't pre-filled, choose:
   **Export to device** · your **Instagram** profile · **Format: JSON** (not HTML) · **Date
   range: All time** · **Media quality: High** · **Your Instagram activity** (posts, reels and
   stories).
3. Click **Start export**. Meta emails you when it's ready. That takes minutes for small
   accounts and can take a few days for large ones.
4. Download the file(s) from **Available downloads** within 4 days. Large accounts get several
   zips; download them all.

Next to the steps: a "What gets imported" list (posts, carousels, reels, stories, photo
locations) and the out-of-scope list (DMs, likes, comments, followers).

**2. "Choose your export": the file field**
- A read-only text field showing the chosen path(s), with a **Choose file…** button
  (`FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom,
  allowedExtensions: ['zip'])`) and a secondary **Choose folder…** link for an already-unzipped
  export.
- **Validate before importing:**
  - an Instagram export (`your_instagram_activity/` inside) → "Instagram export · @handle ·
    Jun 2012 – Oct 2026 · 4.8 GB · 2 of 2 parts";
  - HTML → "Request it again with Format: JSON";
  - a Facebook export → "This looks like a Facebook export", with a button to switch pages;
  - missing parts → list them, but allow importing anyway.
- An **Import** button, then inline progress (posts, media). The import keeps running in its
  isolate if the user leaves the page. The Downloads watcher can fill the field when an
  `instagram-*.zip` appears in `~/Downloads`.

**3. "Keep it up to date automatically"** (after the first import): explains that Instagram
will send a new export to Google Drive every day for 3 years. It shows Google Drive's
connection status (**Connect Google Drive** first if needed), then a **Set up automatic
export** button that opens the scheduled deep link below. There are fallback steps if the
pre-fill doesn't apply: **Transfer to destination › Google Drive** · **Daily** · **3 years** ·
**JSON** · **Last week**. An **"I've set it up"** confirmation stores the start date, so we can
warn before the schedule ends.

**4. Sync status:** last export imported, new items, next expected, schedule end date, plus
**Import another export…** and **Renew schedule**.

## How the scheduled export works

Meta documents a deep link into EYI that pre-fills every choice, so the user only has to confirm
([Deeplinking Guide](https://developers.facebook.com/documentation/data-portability/deep-link-guide)):

```text
https://accountscenter.instagram.com/info_and_permissions/dyi
  ?source=external&account_type=1
  &import_service=GoogleDrive
  &format=JSON&locale_override=en_US&quality=HIGH
  &sections[0]=IG_YOUR_ACTIVITY
  &date_range=LAST_WEEK
  &schedule_frequency=ONCE_A_DAY_FOR_THREE_YEARS
```

- `account_type=1` is Instagram (`0` is Facebook). The same tool and the same parameters serve
  both.
- `schedule_frequency`: daily, weekly or monthly for 1, 2 or 3 years (yearly for 2 or 3).
  There's no "forever" and no hourly. Default to **daily for 3 years**
  (`ONCE_A_DAY_FOR_THREE_YEARS`).
- `date_range=LAST_WEEK` on a daily schedule makes each export overlap the previous week. The
  idempotent upsert absorbs the duplicates, and a missed or failed day leaves no gap.
- `locale_override=en_US` keeps field names English, so the parser handles one locale.
- `quality=HIGH` gets the best media Meta offers in exports.
- `sections`: `IG_YOUR_ACTIVITY` is the documented Instagram activity section. Whether it
  includes posts, reels and stories, or whether they need further values, is a spike question.

## The user's flow

1. **First run: full backfill.** One `ALL_TIME` export. The user either:
   - downloads it and drags the zip(s) onto the Instagram page (or the Downloads watcher picks
     up `instagram-*.zip`), or
   - sends it to Drive like the scheduled ones.

   Large accounts get several zips. Import them in any order; the upsert doesn't care.
2. **"Keep Instagram in sync" button:** opens the scheduled deep link in the user's browser. If
   Google Drive isn't connected in My Data Studio yet, connect it first. It's the delivery
   channel.
3. **Every day after that:** Meta drops an export into the user's Drive. The Google Drive scanner
   (`modules/files/services/scanners/google_file_scanner.dart`) recognises Meta export zips in
   EYI's folder, downloads them, and hands them to the Instagram import isolate rather than
   indexing them as plain files. Imported zips can then be deleted from Drive (opt-in setting)
   to save the user's Drive quota.
4. **Before the schedule ends:** store the schedule's end date (set-up date + chosen duration).
   30 days before, show "Your Instagram sync ends on <date> — renew", which reopens the deep
   link. Also flag Instagram **stale** if no export has arrived in 3× the scheduled interval
   (the schedule might have been cancelled in Accounts Center, or Drive disconnected).

**Fallback without Google Drive:** a weekly reminder to request a delta export
(`date_range=CUSTOM&start=<last imported timestamp>`) to the device, plus the Downloads watcher.
Never drive Meta's pages with browser automation: it breaks Meta's terms on automated access,
it breaks whenever their UI changes, and it risks getting the user's account flagged.

**What the user sees:** "Last export imported: today, 06:12 · 3 new posts · next expected
tomorrow · schedule ends 14 Oct 2029."

## Spike first (needs a real account; blocks everything below)

- Does the deep link work for a site that isn't registered with Meta as a destination?
  `import_service=GoogleDrive` is Meta's own destination; `source=external` is required. If it's
  refused, fall back to step-by-step instructions with screenshots. The schedule still exists in
  the EYI UI, the user just sets it by hand.
- Does a **scheduled Drive transfer** deliver the same JSON zip as a device download (same
  layout, captions, stories, `exif_data`), or only media? Some third-party guides say partner
  transfers cover only photos and videos. **This decides whether the plan works.** If transfers
  are media-only, captions need a periodic device export, and we redesign around that.
- Which `sections` values cover posts, reels and stories?
- Is a relative `date_range` re-evaluated on each scheduled run, or fixed at request time?
  (If fixed, every scheduled run re-sends the same window, and we need `ALL_TIME` instead. That
  works, but each export is large.)
- Folder and file names EYI writes in Drive; how multi-part exports are named.
- How long a daily export takes to arrive, and what happens when one fails.
- The same answers for Facebook (`account_type=0`). See *Facebook* below.

Record the answers in this plan before building the Drive handoff.

## Parsing the export

1. **Sample export first** (JSON, `locale_override=en_US`). Known shape **(verify)**:
   - `your_instagram_activity/content/posts_1.json` (numbered for large accounts),
     `stories.json`, `reels.json`;
   - media under `media/posts/<YYYYMM>/…`, `media/stories/…`, referenced by relative `uri`;
   - `creation_timestamp` in Unix seconds;
   - some media carry `media_metadata.photo_metadata.exif_data` with `latitude`/`longitude`
     (and sometimes the original capture time), even though the image file's own EXIF is
     stripped.

   Commit a trimmed fixture under `client/test/fixtures/`.
2. **Text decoding:** Meta's exporter escapes UTF-8 bytes as Latin-1 code points
   (`â\u0080\u0099` instead of `’`). Re-encode such strings to Latin-1 bytes and decode as UTF-8,
   in a shared `meta_export_text.dart` helper (Facebook exports need it too). Fixture test with
   emoji and accents.
3. **Parser** (pure Dart, no I/O). Locate files by pattern, not hard-coded paths, so a layout
   change fails loudly instead of silently importing nothing.
   - **Posts and carousels:** one `social_posts` row (`kind = post` or `carousel`) linked to N
     `files` rows in order (`position`).
   - **Reels:** `kind = reel`, one video file.
   - **Stories:** `kind = story`, one media file each.
   - **Caption** → `text`; `title` on multi-media posts → `text` when the per-item captions are
     empty.
   - **Identity:** the export has no Graph ids **(verify)**. Derive `external_id` from a stable
     hash of `(kind, creation_timestamp, first media uri basename)`. Basenames stay the same
     across exports **(verify across two exports)**; if not, use `(kind, creation_timestamp,
     caption hash)`. The upsert keys on `(platform, external_id)`.
4. **Import isolate:** one-time isolate in the style of the PST import, started by the UI (drag
   and drop, Downloads watcher) or by the Drive scanner's handoff. Writes go through
   `writeViaMain()` (single-writer rule). Unzip into a temp dir; copy media into the app's
   storage; record the zip's hash in an `imported_exports` table so the same zip is never
   imported twice.

## Storage

Uses the **shared social foundation** ([social-x-sync.md](social-x-sync.md),
ADR 0002), with `platform = 'instagram'`:
- `social_posts`: `kind`, `text`, `created_at`, `latitude`/`longitude` (from the first media
  item that has `exif_data`), `raw_json`.
- **Media into `files`**, with `social_post_id` and `position` (columns added by the Facebook
  plan). `date_created` = the capture time from `exif_data` when present, else
  `creation_timestamp`. `latitude`/`longitude` from `exif_data`. The photos then show up in
  Photos, on the map and in `near:`, with thumbnails, descriptions, image embeddings and
  clustering at no extra cost.
- **No `deleted_on_source_at` from exports alone:** a post missing from a `LAST_WEEK` export
  just wasn't in that window. Deletion can only be inferred by comparing a full `ALL_TIME`
  export, so don't infer it. The archive keeps everything, which is the point.

## Embeddings

- Images carry most of the search value. They're in `files`, so the existing `EmbeddingIsolate`
  already embeds and describes them.
- Post text embedding: caption with a short prefix ("Instagram post, 2021-08-02: …"). Strip a
  trailing hashtag block before embedding, but keep hashtags in the FTS index, so `#banff`
  matches by keyword.
- Caption-less posts get no text embedding. They're found through their images.

## Search

Shared foundation: `SearchResultType.social`, `type:social` and `type:instagram` filters, FTS5
over captions, a vector retriever over `social_posts_embeddings`, `HybridRanker`, and `social`
as an LLM `search` source (ADR 0001). `near:` works for posts whose media had `exif_data`.

## The UI

`InstagramPage`, two views over the same data:
- **Grid** (default): 3-column square thumbnails, newest first, with month headers, sharing the
  Photos module's tile and thumbnail code. Carousel and reel badges.
- **Feed:** the shared `SocialPostCard` (caption with linkified hashtags and @mentions, media,
  location chip, "Open on Instagram" when a permalink is known). No like or comment counts.
- **Post detail:** a carousel swiper over the post's files in the Photos viewer, caption below.
- **Stories strip:** past stories grouped by day, played from local files.
- **Toolbar:** search scoped to `type:instagram`; filters for Reels, Carousels, Stories, a year
  picker; **On this day**.
- **Empty state and sync settings:** the setup and import panel above. A gear icon in the
  toolbar reopens it, along with the stale and renew warnings.

## Dedupe with the camera roll

Many Instagram photos are already in the library from the phone's camera roll or Google Drive,
at higher quality. Default: **link, don't delete**. When a perceptual hash or image-embedding
match is above a threshold, set `files.duplicate_of`, and have Photos show the original with an
"Also posted to Instagram" badge. **Not in v1** unless the spike shows duplicates swamp the
Photos timeline.

## Facebook

[social-facebook-sync.md](social-facebook-sync.md) uses the same approach: the same EYI tool and
deep link, with `account_type=0`. Its Graph API path is likewise deferred, until business
verification. Run the spike for both platforms at once. Written once and shared:
`MetaExportSetupPanel`, the Drive handoff, `imported_exports`, the Downloads watcher, the
schedule lifecycle, `meta_export_text.dart` and `SocialPostCard`.

## Deferred: API sync for professional accounts

Not planned for v1. Kept here so the research isn't lost. Build it only if real users need what
the export can't do: a backfill without Drive, or stories captured within hours.
- Instagram API with Instagram Login, host `graph.instagram.com`, scope
  `instagram_business_basic` (Advanced Access via App Review). Professional accounts only.
- Code flow: webview intercepts `https://auth.xdtlabs.com/instagram/callback`. The token service
  (Facebook plan, Cloud Run) exchanges the code and then the short-lived token (both need the
  app secret) for a 60-day token. Refresh (`ig_refresh_token`) needs no secret and works once
  the token is 24h old, so the client can keep a connection alive indefinitely.
- `GET /me/media` with `children`; `/me/stories` returns only live stories (poll every 6h).
  There's **no location field**, and no `media_url` for licensed-audio reels.
- Reuses `MetaGraphClient` / `MetaSocialScanner` from the Facebook plan. API-synced and exported
  items must merge, but the API's media ids and the export's identity hash differ, so they need
  a matching rule on `(timestamp, caption)`.

## Tests

- Parser against the fixture: carousel order, a reel, a story, `exif_data` → lat/lng and capture
  date, numbered `posts_N.json`, mojibake decoding.
- Identity: the same post in two different exports (`LAST_WEEK` then `ALL_TIME`) gives one row.
- File-field validation: HTML export rejected, Facebook export detected, missing parts listed.
- Idempotency: importing the same zip twice is a no-op (`imported_exports`); overlapping
  windows add no duplicates.
- Drive handoff: a Meta export zip in the EYI folder goes to the importer, not the file index.
  Other zips are indexed as normal.
- Schedule lifecycle: the renew warning appears 30 days before the end; the stale flag appears
  after 3× the interval with no export.

## Done when

- A **personal** account user imports a full export and gets the grid, feed, stories and search,
  with captions decoded correctly.
- After a one-click schedule setup, new posts appear in the app within about a day, with nobody
  doing anything, for the life of the schedule. Overlapping exports add no duplicates.
- Photos with `exif_data` appear on the map and match `near:`. Every photo and video sits in
  Photos at its real date, carousels in order.
- A lapsed, cancelled or stalled schedule shows a visible state ("Instagram sync stopped" /
  "renew"), never silence.

## Open questions

- Delete imported zips from the user's Drive automatically, or keep them (they count against
  the user's Drive quota)? Default proposal: opt-in delete.
- Daily vs weekly default: daily gives freshness, weekly is gentler on Drive storage. Default
  proposal: daily, with overlapping windows.
