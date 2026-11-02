---
status: proposed
adr: none
remaining: [export-spike, portability-api-spike, sample-export, export-parser, media-fetch, import-isolate, setup-import-ui, portability-sync, embeddings, search, grid-ui]
---

# Plan: Archive TikTok posts

> **Not ready to implement.** Every path below depends on things only a real export and a real
> developer application can confirm: whether the export's video links still download, how long
> they last, and what the Data Portability API actually returns. Run the **spike** first, record
> the answers here, then revise this plan before writing code.

There's no TikTok placeholder in the `social` module yet. This plan adds a `TikTokPage`, using
the same setup-panel and feed pattern as the [Facebook](social-facebook-sync.md),
[Instagram](social-instagram-sync.md) and [X](social-x-sync.md) plans.

**Scope: an archive of what the user posted, not a TikTok client.** That means the user's own
videos and photo posts, with captions, sounds and locations. Out of scope: DMs, likes,
favourites, watch history, comments, followers and engagement counts.

> Facts below were checked against TikTok's developer docs and third-party guides on
> 2026-10-25. Items marked **(verify)** are unconfirmed.

## The three ways in, and what each lacks

| | Who can use it | Video files? | Ongoing sync? | Approval |
|---|---|---|---|---|
| **"Download your data"** (in-app export, JSON) | Everyone | **Links only** (verify whether they download) | No: one-time, manual | None |
| **Data Portability API** (DMA) | **EEA and UK users only** | **Yes**: download URLs for `.mp4` / `.jpg` | **Yes**: `.ongoing` scopes | Application + Login Kit review (~3–4 weeks) |
| **Display API** (`video.list`) | Everyone | **No**: metadata, cover image, share/embed link | Metadata only | Login Kit review |

There's no route that gives every user both the files and automatic updates. So:
- **Export import for everyone** is the base.
- **The Portability API** is the automatic path for EEA/UK users.
- The **Display API** is at most a "new videos since your last export" nudge (deferred).

## Spike (blocks everything)

With a real account, in and outside the EEA/UK:
1. Request **Download your data** in JSON. Record the layout: the posted-video list, its fields
   (date, caption, link, sound, location?), and how photo posts appear.
2. **Do the posted-video links download the MP4?** Try right after the export arrives and again
   days later. Do they need a signed-in session? Are they watermarked? Do they expire? **If they
   don't download, the export path archives captions and dates only**, and the plan changes.
3. Apply for the **Data Portability API** (`portability.postsandprofile.ongoing`) with UX
   mockups. Record the response format, how long the media URLs last, and whether location is
   coordinates or a place name.
4. Check whether "Recently deleted posts" in the Portability data include media.
5. Test the Display API's `video.list` fields and their freshness, only if the nudge is worth
   keeping.

## Path 1: export import (all users)

**Setup UI on `TikTokPage`** (the shared setup-panel pattern):
1. **"Export your TikTok data":** step-by-step instructions. In the TikTok app: **Profile › ☰ ›
   Settings and privacy › Account › Download your data** → **Format: JSON** → **Request data**.
   TikTok prepares it in 24 hours to 4 days. Download it from the **Download data** tab within 4
   days. No deep link is known **(verify)**.
2. **"Choose your export":** a read-only path field, **Choose file…** (`file_picker`, `.zip` /
   `.json`), validated before importing (a TikTok export, JSON not TXT, which account, date
   range).
3. **Import** with progress: posts parsed, then videos downloaded from their links (if the spike
   says they work). Failed or expired links are listed, with "Re-export to retry".
4. **"Keep it up to date":** there's no scheduled export, so offer a reminder (monthly, user
   choice) to re-export. The import is idempotent, so re-importing the whole thing only adds
   what's new.

**Parser** (pure Dart): locate the posted-video list by pattern, map each entry to a
`social_posts` row (`platform = 'tiktok'`, `kind = video` or `photo`), with caption, date, sound
name and location if present. `external_id` = the video id parsed from the link **(verify that
it's stable across exports)**.

**Media fetch:** download each linked MP4/JPG into the app's storage as a `files` row with
`social_post_id`, so it appears in Photos with thumbnails, descriptions and embeddings. Throttle
and retry politely. If links require a TikTok session, stop: we don't scrape behind a login.

## Path 2: Data Portability API (EEA and UK users)

The only path with automatic sync and guaranteed media.
- **Auth:** Login Kit (OAuth) with `portability.postsandprofile.ongoing`. Whether the code
  exchange needs a client secret decides whether this needs the server-side token service from
  the Facebook plan's deferred section **(verify)**.
- **Flow:** **Add Data Request** → poll **Check Status** (no webhook server needed, which suits a
  desktop app) → **Download** within 4 days → the same parser and importer as Path 1. Each
  ongoing request returns the **full** data for the scope, so the upsert handles the overlap.
- **Schedule:** weekly, via the `ScannerManager` periodic trigger (built for Facebook). It's a
  full re-export each time, so weekly beats daily.
- **Region:** TikTok returns nothing for users outside the EEA/UK. Detect that (the API's
  response or the user's own confirmation), and fall back to Path 1 with a clear message.
- **Prerequisites:** a TikTok developer account; an app registered (at least Draft) with UX
  mockups; the Data Portability application and Login Kit review (~3–4 weeks); a privacy policy
  on xdtlabs.com that names TikTok.

## Deferred: Display API nudge

`video.list` (public videos only, metadata only) could tell users "3 new TikToks since your last
export — re-export to archive them". Not worth Login Kit review on its own. Revisit if Path 1
users ask for it.

## Storage, search and UI

All from the shared social foundation ([social-x-sync.md](social-x-sync.md), ADR 0002):
- `social_posts` + media in `files` (`social_post_id`, `position`);
- `type:tiktok` search filter; text embeddings over caption + sound name; videos embedded and
  described by the existing `EmbeddingIsolate`;
- `TikTokPage`: a grid view (vertical 9:16 thumbnails) plus the shared feed card, playback
  through the Photos viewer, "On this day", and a sync-settings gear;
- location → `near:` and the map, if the spike shows TikTok exports coordinates or a resolvable
  place name.

## Done when

- A user anywhere follows the on-page steps, picks their export, and gets every post they
  published, with video files if the spike confirms the links work, and captions and dates in
  any case. Re-importing adds nothing twice.
- An EEA/UK user connects once and gets new posts weekly, with media, unattended.
- Posts are found by keyword and `type:tiktok`, and videos by a semantic query.

## Open questions

- If the export's links don't download, is a captions-and-dates archive worth shipping outside
  the EEA/UK?
- Deduplicate against originals already in the user's camera roll (common for TikTok creators)?
