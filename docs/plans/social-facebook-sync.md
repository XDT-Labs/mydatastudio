---
status: proposed
adr: none
remaining: [scheduled-export-spike, sample-export, schema-adr, export-parser, import-isolate, setup-import-ui, drive-handoff, downloads-watcher, schedule-lifecycle, media, places, embeddings, search, feed-ui]
---

# Plan: Keep a Facebook archive in sync with scheduled exports

`client/lib/modules/social/pages/facebook_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Facebook" button. There's nothing behind
either.

This plan replaces them with a Facebook archive that **stays up to date by itself**. The user
imports one full JSON export from Meta's Export Your Information (EYI) tool. Then they set up a
**scheduled export** that EYI delivers to their Google Drive every day, for up to three years. We
pick each one up and merge it into the local archive. Posts are stored locally with text
embeddings. Photos and videos land in the Photos module. Check-ins become geo points that
`near:` can find.

It works for **every user**, with no Graph API, no App Review, no business verification and no
token service. [Instagram](social-instagram-sync.md) uses the same approach and shares most of
the code.

**Scope: an archive of what the user posted, not a Facebook client.** That means the user's own
posts, the photos and videos in them, their albums and their check-ins. Out of scope: Messenger,
other people's posts and comments, comments the user left on other people's posts, and
engagement (reactions, comment and share counts). If the user didn't post it, we don't import
it.

> Facts below were checked against Meta's docs on 2026-10-25. Items marked **(verify)** need a
> test against a real account. The spike below exists to answer them.

## Why export-first, Graph API later

- The export **can be scheduled** (daily, weekly or monthly, for 1–3 years), so it handles
  ongoing sync as well as the backfill. It isn't only a one-time download.
- It's **complete**: posts, check-ins with coordinates, photos, videos and albums, for any
  account.
- It needs **nothing from Meta's review processes**. The Graph API needs business verification,
  App Review for `user_posts` / `user_photos` / `user_videos`, and a server-side token service.
  That's months of lead time, and approval isn't guaranteed (Meta's allowed uses for
  `user_posts` are narrow).

The Graph API path is **deferred until xdtlabs is business-verified** (see the last section).
Even then, build it only if it gives users something the export can't, such as faster freshness
or no Google Drive dependency.

## Setup and import UI (on the Facebook page)

`facebook_page.dart` shows this until the first import finishes. After that, it lives in a
"Sync settings" panel. The widget is shared with Instagram (`MetaExportSetupPanel`,
parameterised by platform), in `modules/social/widgets/`.

**1. "Export your Facebook data": step-by-step instructions**, numbered, with the Meta UI words
in bold so the user can match what they see:
1. Click **Open Facebook export page**. This opens the EYI deep link in the user's browser,
   pre-filled for a one-time full export to their device:
   `…/dyi?source=external&account_type=0&format=JSON&date_range=ALL_TIME&quality=HIGH&locale_override=en_US&sections[0]=POSTS_YOUR_ACTIVITY`
   **(verify which `import_service` value means "to device")**.
2. If anything isn't pre-filled, choose: **Export to device** · **Format: JSON** (not HTML) ·
   **Date range: All time** · **Media quality: High** · under the data types, **Your Facebook
   activity › Posts**.
3. Click **Start export**. Meta emails you when it's ready. That takes minutes for small
   accounts and can take a few days for large ones.
4. Download the file from **Available downloads** within 4 days. Large accounts get several zip
   files; download them all.

Next to the steps: a small "Why JSON?" note and a "What gets imported" list (posts, check-ins,
photos, videos, albums), plus the out-of-scope list, so nobody expects Messenger.

**2. "Choose your export": the file field**
- A read-only text field showing the chosen path(s), with a **Choose file…** button:
  `FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.custom,
  allowedExtensions: ['zip'])`, the same `file_picker` package the Photos import dialog uses. A
  secondary **Choose folder…** link (`getDirectoryPath()`) accepts an export the user has
  already unzipped.
- **Validate before importing**, with no import on failure:
  - looks like a Facebook export (`your_facebook_activity/` inside) → show "Facebook export ·
    Mar 2009 – Oct 2026 · 2.3 GB · 3 of 3 parts";
  - HTML format detected → "This export is HTML. Request it again with Format: JSON";
  - an Instagram export picked on the Facebook page → "This looks like an Instagram export",
    with a button to switch pages;
  - a multi-part export with parts missing → list the missing part numbers. Allow importing
    anyway (parts are independent).
- An **Import** button, then inline progress: "Importing posts 1,240 / 4,100 · media 3.1 /
  9.8k". The user can leave the page; the import keeps running in its isolate.
- Also offered: the Downloads watcher (below) can fill this field automatically when a
  `facebook-*.zip` appears in `~/Downloads`. "We found an export in Downloads. Import it?"

**3. "Keep it up to date automatically"** (shown once the first import has finished)
- Explains what will happen: "Facebook will send a new export to your Google Drive every day
  for 3 years. My Data Studio imports it automatically."
- Shows Google Drive's connection status. If Drive isn't connected, **Connect Google Drive**
  first (the existing Drive file source).
- A **Set up automatic export** button opens the scheduled deep link (below). There are fallback
  steps if the pre-fill doesn't apply: **Transfer to destination › Google Drive** ·
  **Frequency: Daily** · **Duration: 3 years** · **JSON** · **Last week**.
- An **"I've set it up"** confirmation stores the schedule's start date, so we can warn before
  it ends.

**4. Sync status** (after setup): "Last export imported: today, 06:12 · 3 new posts · next
expected tomorrow · schedule ends 14 Oct 2029" plus **Import another export…** (the same file
field) and **Renew schedule**.

## The scheduled export

The deep link, as documented in Meta's
[Deeplinking Guide](https://developers.facebook.com/documentation/data-portability/deep-link-guide):

```text
https://accountscenter.facebook.com/info_and_permissions/dyi
  ?source=external&account_type=0
  &import_service=GoogleDrive
  &format=JSON&locale_override=en_US&quality=HIGH
  &sections[0]=POSTS_YOUR_ACTIVITY
  &date_range=LAST_WEEK
  &schedule_frequency=ONCE_A_DAY_FOR_THREE_YEARS
```

- `schedule_frequency`: daily, weekly or monthly for 1, 2 or 3 years (yearly for 2 or 3).
  There's no "forever" and no hourly. Daily is plenty for a personal timeline.
- `date_range=LAST_WEEK` on a daily schedule makes each export overlap the previous week. The
  idempotent upsert absorbs the duplicates, and a missed or failed day leaves no gap.
- `locale_override=en_US` keeps field names English, so the parser handles one locale.

**Pick-up:**
- The Google Drive scanner (`modules/files/services/scanners/google_file_scanner.dart`)
  recognises Meta export zips in EYI's Drive folder. It downloads them and hands them to the
  Facebook import isolate, instead of indexing them as plain files. Deleting imported zips from
  Drive is an opt-in setting, to save the user's Drive quota.
- **Schedule lifecycle:** 30 days before the schedule ends, show "Your Facebook sync ends on
  <date> — renew". If no export has arrived in 3× the interval, flag Facebook as **stale** (the
  schedule may have been cancelled in Accounts Center, or Drive disconnected).
- **Without Google Drive:** a weekly reminder to request a delta export
  (`date_range=CUSTOM&start=<last imported timestamp>`) to the device. The file field and the
  Downloads watcher take it from there. Never drive Meta's pages with browser automation: it
  breaks Meta's terms on automated access, it breaks whenever their UI changes, and it risks
  getting the user's account flagged.

## Spike first (needs a real account; blocks the scheduled path)

Run it once for Facebook and Instagram together:
- Does the deep link work for a site that isn't registered with Meta as a destination?
  `source=external` is required. If it's refused, the setup panel falls back to the
  step-by-step text above. The schedule still exists in the EYI UI.
- Does a **scheduled Drive transfer** deliver the same JSON zip as a device download, or only
  media? Some third-party guides say partner transfers cover only photos and videos. **This
  decides whether the scheduled path works.** If it's media-only, the fallback (periodic device
  delta exports) becomes the main ongoing-sync path.
- Is a relative `date_range` re-evaluated on each scheduled run, or fixed at request time?
- Which `import_service` value (if any) means "export to device" for the one-time pre-filled
  link?
- Folder and file names EYI writes in Drive; how multi-part exports are named.
- How long a daily export takes to arrive, and what happens when one fails.

The one-time import (setup UI steps 1–2) doesn't depend on the spike. Build it first.

## Parsing the export

1. **Sample export first.** The folder layout changes between export versions, so record a real,
   recent one before writing the parser. Known shape **(verify)**:
   - `your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json`, numbered
     `_1`, `_2`, … for large accounts;
   - `your_facebook_activity/posts/album/<n>.json` for albums;
   - media referenced by relative `uri` paths into the export;
   - Unix-second `timestamp` / `creation_timestamp` fields;
   - per post: `data[].post` (text), `title` (the auto-generated "Mike shared a link" line),
     `attachments[].data[]` holding `media{uri,title,description,creation_timestamp,
     media_metadata}`, `place{name,coordinate{latitude,longitude},address}` or
     `external_context{url,name}`, plus `tags`.

   Commit a small trimmed fixture under `client/test/fixtures/`.
2. **Text decoding.** Meta's JSON exporter escapes UTF-8 bytes as Latin-1 code points
   (`â\u0080\u0099` instead of `’`). Re-encode such strings to Latin-1 bytes and decode as UTF-8,
   in a shared `meta_export_text.dart` helper (Instagram needs it too). Otherwise every accented
   character and emoji is garbled. A fixture test must cover it.
3. **Parser** (pure Dart, no I/O): posts, check-ins (place name plus coordinates), photos and
   videos with captions, shared links, albums. Locate files by pattern, not hard-coded paths, so
   a layout change fails loudly instead of silently importing nothing.
4. **Identity:** the export has no Graph post ids **(verify)**. Derive `external_id` from a
   stable hash of `(timestamp, text, first media uri basename)`. Check across two exports that
   it doesn't change. The upsert keys on `(platform, external_id)`.
5. **Import isolate:** a one-time isolate in the style of the PST import, started by the file
   field, the Downloads watcher or the Drive handoff. Writes go through `writeViaMain()`
   (single-writer rule). Unzip to a temp dir, copy media into the app's storage, and record each
   zip's hash in `imported_exports` so the same zip is never imported twice.

## Storage

This plan builds the **shared social foundation** described in
[social-x-sync.md](social-x-sync.md), if Facebook goes first. Record the
schema in **ADR 0002** before writing it.

**`social_posts`** (shared table; Facebook values shown)
- `id` (our UUID), `collection_id`, `platform = 'facebook'`, `external_id` (the identity hash
  above; a Graph id if the deferred API path is ever built). Unique on
  `(platform, external_id)`, so every write is an upsert.
- `kind`: `post`, `photo`, `video`, `link`, `checkin`, `shared`, `life_event`, derived from the
  attachments.
- `text` = the post text. The auto-generated `title` line goes in a separate `story` column:
  useful to show, noisy to embed.
- `created_at`, from `timestamp`.
- `place_name`, `latitude`, `longitude`, `address`, from `place`.
- `link_url`, `link_title`, from `external_context`.
- `raw_json`: the post's JSON, so later parser versions can re-derive columns without needing
  the export again.
- No deletion inference: a post missing from a `LAST_WEEK` export just wasn't in that window.
  The archive keeps everything, which is the point.

**Media goes into `files`**, the same way email attachments do:
- Add a `social_post_id` column to `files`, mirroring `email_id`. Add a `position` column for
  order within a post.
- `collection_id` is the Facebook collection. `local_path` is the copied file. `date_created`
  is the media's `creation_timestamp`, so it sorts into the right month in Photos.
- **Location:** use the media's `exif_data` coordinates when present. Otherwise copy the post's
  check-in `latitude`/`longitude` onto every photo in it. Photos on the map then come for free.
- `description` is the photo's caption.
- Facebook albums map onto the existing `albums` / `album_files` tables. The user's "Banff 2019"
  album appears as an album in Photos.
- `PhotoSource` gets a `socialPostId`, as it has `emailId`, so the info sidebar can link back to
  the post.

**Embeddings:** `social_posts_embeddings`, the same shape as `emails_embeddings` (Qwen3-VL,
2048 dimensions). Images don't need anything new: they're rows in `files`, so the existing
`EmbeddingIsolate` already embeds and describes them.

## Places and `near:`

- A check-in gives coordinates directly. Store them on the post and on its photos.
- A place with a name but no coordinates: resolve the address/city through the existing
  gazetteer (`gazetteer_repository.dart`) to a centre point, flagged `geo_precision = 'city'`.
- Extend `NearResolver`'s candidate query (today it searches `files` lat/lng) to include
  `social_posts`. `near:banff` then returns the check-in post and its photos.
- `place_name` is indexed in FTS too. Typing "Moraine Lake" finds the check-in without `near:`.

## Embeddings

- **What to embed per post:** `text` + `place_name` + `link_title` in one string, with a short
  prefix ("Facebook post, 2019-07-14, at Moraine Lake: …"). Skip `story`.
- Photo-only posts get no text embedding. They're found through their images. A search hit on
  a file with a `social_post_id` surfaces its post in social results, as an attachment hit
  surfaces its email.
- **Isolate:** generalize `EmailEmbeddingIsolate` into a text-row embedder that takes a table,
  rather than copying it. Decide this in ADR 0002.

## Search and LLM tools

From the shared foundation:
- `SearchResultType.social`, plus `type:social` and `type:facebook` filters;
- an FTS5 index over `text`, `place_name` and `link_title`;
- a vector retriever over `social_posts_embeddings`;
- all merged by `HybridRanker`;
- `social` as a `sources` value on the LLM `search` tool (ADR 0001).

## The feed UI

**Build the feed natively. Don't embed Facebook's post widget.** The official embed plugin only
works for public posts, needs a network connection, loads Facebook's tracking scripts, and
breaks offline. That defeats the archive.

Once data exists, `facebook_page.dart` becomes a `FacebookFeedPage`:
- **List:** `ListView.builder` over a paged repository query (50 at a time, newest first), with
  sticky **month/year headers** and a year jump bar down the side.
- **`SocialPostCard`** (shared with Instagram and Twitter):
  - **header:** name, date (full date on hover), "at Moraine Lake" when there's a place;
  - **body:** text with URLs linkified. Long posts collapse at 8 lines with "See more". The
    `story` line is shown in muted type above;
  - **media:** Facebook-style grids — one full width; two side by side; three as one large plus
    two small; four or more as a 2×2 grid with "+N". Tapping opens the existing Photos viewer
    on those files;
  - **link card:** title and domain. Click opens in the browser via `url_launcher`;
  - **check-in:** a small static `flutter_map` tile with a pin. Click → Photos map view centred
    there;
  - no reaction, comment or share counts: this is an archive of what the user posted.
- **Toolbar:** search scoped to `type:facebook`, filter chips (Has photos, Check-ins, Links, a
  year picker), **On this day**, and a gear icon for the sync settings panel.
- **States:** the setup panel when empty; import progress; "Facebook sync stopped — no export
  since <date>"; "Schedule ends in 30 days — renew".

## Shared with Instagram

`MetaExportSetupPanel`, the Drive handoff, the Downloads watcher, `imported_exports`, the
schedule lifecycle, `meta_export_text.dart` and `SocialPostCard` are written once and
parameterised by platform. Whichever plan is built first builds them.

## Tests

- Parser against the fixture: numbered `_N.json` files, a multi-photo post, a check-in, a shared
  link, an album, mojibake decoding.
- Identity: the same post in two different exports gives one row.
- Idempotency: the same zip twice is a no-op; overlapping windows add no duplicates.
- File-field validation: HTML export rejected, Instagram export detected, missing parts listed.
- Drive handoff: a Meta export zip in EYI's folder goes to the importer, not the file index.
- Photos: a check-in photo gets the post's coordinates; an album maps to `albums`.
- Schedule lifecycle: the renew warning appears 30 days before the end; the stale flag appears
  after 3× the interval with no export.

## Done when

- A user follows the on-page instructions, picks their export zip(s), and gets every post with
  correctly decoded text (emoji and accents intact). Re-importing changes nothing.
- After a one-click schedule setup, new posts appear within about a day, with nobody doing
  anything, for the life of the schedule.
- Photos from posts appear in Photos, in their Facebook albums. Check-in photos appear on the
  map.
- A known post is found by keyword, by a semantic query, by `type:facebook`, and by `near:` for
  a check-in.
- A stalled or ending schedule produces a visible prompt, never silent failure.

## Open questions

- Delete imported zips from the user's Drive automatically? Default proposal: opt-in.

## Deferred: Graph API sync (after business verification)

Not in v1. Kept so the research isn't lost. Revisit once xdtlabs is business-verified, and
build it only if users need what the export can't do: freshness within hours, or no Google Drive.
API-synced posts would upsert into the same `social_posts` rows, but Graph ids differ from the
export's identity hash, so they need a matching rule on `(created_at, text)`.

**Prerequisites** (owner: Mike; lead time weeks):
- [ ] Meta Business portfolio for xdtlabs **verified**: legal name, address and phone matching the
      documents exactly; one proof of legal identity plus one proof of address; xdtlabs.com
      verified via DNS TXT. Takes days to about 2 weeks, sometimes 30 days.
- [ ] Meta app (Facebook Login, purpose "Clients") linked to the business; testers added; embedded
      browser OAuth login on, with `https://www.facebook.com/connect/login_success.html` as a
      valid redirect URI **(verify the desktop toggles)**
- [ ] App name and 1024×1024 icon without Meta trademarks; category; a monitored contact email
- [ ] Privacy policy, terms and data-deletion pages on xdtlabs.com (data stays on the user's
      device; the token service sees tokens, never content)
- [ ] Token service deployed (below)
- [ ] A unique usage paragraph per permission ("private digital album and searchable archive of
      your own timeline, stored only on your computer")
- [ ] Notarized downloadable build, a reviewer test account with sample posts, photos, an album
      and a check-in, and install-to-feed instructions
- [ ] Each permission called within 30 days of submitting
- [ ] Screen recordings, one per permission: 1080p, English UI, enlarged cursor, no audio,
      window ≤1440px wide
- [ ] Submit (Data Handling Questions appear only after verification; target decision within
      about a week) → approved → Live mode → yearly Data Use Checkup on the calendar
      **(verify cadence)**

**Permissions:** `user_posts`, `user_photos`, `user_videos` (+ `public_profile`). Meta's allowed
uses include "physical or digital books or albums of their timelines", which is the framing for
review. Request nothing else.

**Token service** (needed because Meta's desktop login returns a token lasting hours, and
exchanging it for a ~60-day token needs the app secret, which must never ship in the client):
- **Python FastAPI** in a new top-level `tokenservice/` directory (PDM, pytest, like `aiserver/`),
  one container on **GCP Cloud Run** in its own project, custom domain `auth.xdtlabs.com`,
  `--allow-unauthenticated`, `min-instances=0`, a low `max-instances`, 10s timeout.
- Endpoints: `POST /facebook/exchange` (runs `debug_token` and refuses tokens not issued to our
  app id, then exchanges the token); `POST /facebook/deauthorize` and
  `POST /facebook/data-deletion` (verify the `signed_request` HMAC; deletion returns a status URL
  on xdtlabs.com). JSON only. User data never passes through it, and it stores nothing.
- `FACEBOOK_APP_SECRET` in Secret Manager, readable only by the service account. Never log
  tokens. The service URL reaches the app as a `--dart-define`.

**Client:**
- **Login:** a webview login controller (`webview_flutter`) that reads the token from the
  `login_success.html` fragment and stores it in `collections.access_token` / `expiration`.
- **Re-auth:** no refresh endpoint exists, so show "Reconnect Facebook" 7 days before expiry.
  Error 190 → `needs_re_auth`.
- **Graph client:** a pinned version, `GET /me/posts` with only the stored fields
  (`message, created_time, updated_time, permalink_url, place{…}, attachments{…, subattachments}`),
  following `paging.next`.
  - Full-resolution photos via `/{photo-id}?fields=images`, using the batch API.
  - Download media in the same pass, because CDN URLs expire.
  - Back off on `X-App-Usage` above 75%, and on error codes 4, 17 and 32.
- **Sync:** a `FacebookScanner` that:
  - backfills with a resumable cursor in `social_sync_state`;
  - runs incrementally each day with `since` minus a 1-day overlap;
  - re-fetches the last 30 days to catch edits;
  - does a weekly id-only reconcile that marks `deleted_on_source_at`.

  It needs the `ScannerManager` periodic trigger.
- **Shared code:** build `MetaGraphClient` / `MetaSocialScanner` generically, so the deferred
  Instagram API path can reuse them.
