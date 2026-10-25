---
status: proposed
adr: none
remaining: [meta-app-instagram-product, token-service-instagram, app-review, ig-graph-client, backfill, incremental-sync, stories-capture, archive-import, media, embeddings, search, grid-ui]
---

# Plan: Sync Instagram through the Instagram API (plus archive import)

`client/lib/modules/social/pages/instagram_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Instagram" button.

This plan is the Instagram twin of [social-facebook-sync.md](social-facebook-sync.md). It
reuses the same Meta app, token service, schema, sync machinery and feed widgets. Read that plan
first. This one only describes what's **different** for Instagram.

**Scope: an archive of what the user posted, not an Instagram client.** That means the user's
own feed posts, carousels, reels and stories, with their captions. Out of scope: DMs, other
people's posts and comments, comments the user left elsewhere, likes, followers, and engagement
counts (`like_count`, `comments_count` and the rest). Same rule as Facebook: if the user didn't
post it, we don't fetch it.

> Facts below were checked against Meta's Instagram Platform docs on 2026-10-25. Items marked
> **(verify)** need a test against a real account.

## Reuse from the Facebook plan

Meta's API for Instagram is the same **Graph API** style as Facebook (REST + field selection +
cursor paging; it isn't GraphQL), on a different host. So most of the Facebook work carries
over:

| Facebook piece | Reused for Instagram? |
|---|---|
| Meta app, business verification, privacy/terms/deletion pages on xdtlabs.com | **Yes, as is.** Add the *Instagram* product to the same app. One business verification covers both. |
| App Review process (recordings, reviewer account, 30-day API calls) | **Yes.** One more permission in the same, or a later, submission. |
| Token service on Cloud Run (Python FastAPI) | **Yes.** Add `POST /instagram/exchange`. Same secret handling, same abuse controls. |
| `social_posts`, `social_posts_embeddings`, media in `files` with `social_post_id` | **Yes.** `platform = 'instagram'`. |
| Graph client patterns: pinned version, field lists, `paging.next`, rate-limit headers, error → `needs_re_auth` | **Yes.** Share a base `MetaGraphClient` (host + token + paging + backoff). Facebook and Instagram become thin subclasses. |
| `FacebookScanner` backfill / incremental / edits / reconcile, `social_sync_state` | **Yes.** Same phases, generalized to `MetaSocialScanner` with a per-platform fetcher. |
| Periodic trigger in `ScannerManager` | **Yes.** Built once for Facebook. |
| `SocialPostCard`, feed paging, search, `type:` filters, LLM `sources` | **Yes.** Instagram adds a grid view (below). |
| Check-ins → geo points for `near:` | **No.** The Instagram API has no location field. See *Location*. |
| Webview login on `login_success.html` | **No.** Instagram uses a code flow. See *Auth*. |

**Implication for build order:** build the Facebook plan's shared pieces generically from the
start (`MetaGraphClient`, `MetaSocialScanner`, platform-agnostic `SocialPostCard`). Then
Instagram is mostly configuration plus the differences below.

## The big constraint: professional accounts only

Meta shut down the Instagram Basic Display API, which was how personal accounts read their own
media. The **Instagram API with Instagram Login** only serves **professional accounts**
(business or creator). A personal account can't authorize the app at all.

Options for a personal-account user:
1. **Switch to a creator account.** Free, in Instagram's settings, and reversible. But it
   changes how the account looks to others (category label, insights, contact options), and
   professional accounts may not be able to stay private **(verify the current rule for
   creator accounts)**. We can explain this, but must never push it.
2. **Archive import** (Accounts Center › Export your information, JSON): works for every account
   type.

So this plan has **two paths into the same tables**:
- **API sync** for professional accounts: backfill plus ongoing sync, as with Facebook.
- **Archive import** for everyone: the only path for personal accounts, and a one-time
  enrichment for professional ones. It fills gaps the API can't: location, expired stories,
  and reels whose `media_url` is withheld.

Both upsert on `(platform, external_id)`, so they merge rather than duplicate **(verify that
the export's media ids match the API's `id`; if not, match on `timestamp` + caption hash)**.

## Auth

Business Login for Instagram is an **authorization-code** flow:
1. Open a webview at `https://www.instagram.com/oauth/authorize?client_id=…&redirect_uri=…&
   response_type=code&scope=instagram_business_basic`.
2. `redirect_uri` must exactly match a registered URI. Register
   `https://auth.xdtlabs.com/instagram/callback`. The webview **intercepts** that navigation
   before it loads and reads `code` from the query string, the same trick as Facebook's
   `login_success.html`. Codes are valid for 1 hour, single use.
3. The app POSTs the code to the token service's `POST /instagram/exchange`. The service:
   - exchanges the code at `https://api.instagram.com/oauth/access_token` (needs the app
     secret) for a 1-hour token;
   - immediately exchanges that at `https://graph.instagram.com/access_token?
     grant_type=ig_exchange_token` (also needs the secret) for a **60-day** token;
   - returns the long-lived token and its expiry. It stores nothing.
4. **Refresh is client-side and needs no secret:**
   `GET https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=…`
   works once the token is at least 24 hours old and still valid, and each refresh restarts the
   60-day clock. The scanner refreshes on any run where the token is more than 30 days old.
   **So an Instagram connection never expires as long as the app syncs at least once every
   60 days.** That's better than Facebook, which needs a re-login every ~60 days.
5. If the token does lapse (the app wasn't opened for 60 days), it can't be refreshed:
   `needs_re_auth` → "Reconnect Instagram" banner, same as Facebook.

Permission: **`instagram_business_basic` only.** It reads the profile and media. The other
`instagram_business_*` scopes (publish, comments, messages) are out of scope. App Review needs
**Advanced Access** for it, because we serve accounts we don't own. Same recording rules as
Facebook: show the consent screen, then the grid.

## The Instagram client

`IgGraphClient extends MetaGraphClient`, host `graph.instagram.com`, pinned version.

- **Profile:** `GET /me?fields=user_id,username,name,account_type,profile_picture_url,media_count`.
  Check `account_type` on login, and explain clearly if it isn't professional.
- **Media:** `GET /me/media?fields=id,caption,media_type,media_product_type,media_url,
  thumbnail_url,permalink,shortcode,timestamp,alt_text,is_shared_to_feed,
  children{id,media_type,media_url,thumbnail_url,alt_text}&limit=100`, following `paging.next`.
- `media_type`: `IMAGE`, `VIDEO`, `CAROUSEL_ALBUM`. `media_product_type`: `FEED`, `REELS`,
  `STORY` (`AD` is skipped). This maps to `social_posts.kind`: `post`, `carousel`, `reel`,
  `story`.
- **Carousels:** one `social_posts` row; each `children` item becomes a `files` row with
  `position`. Child media has no caption or permalink of its own.
- **`media_url` is optional.** Meta withholds it for videos with copyrighted or licensed audio
  (including Instagram's own music library) *even for the owner*. Then store `thumbnail_url` as
  a poster image, mark the file `media_unavailable = 'licensed_audio'`, and let a later archive
  import fill in the video.
- **Download immediately.** Treat CDN URLs as expiring, as on Facebook **(verify the lifetime)**.
- **Edits and deletes:** captions can be edited, and there's no `updated_time`. The daily
  re-fetch of the last 30 days compares captions. The weekly id-only reconcile marks
  `deleted_on_source_at`, the same as Facebook.

## Stories: the one place sync frequency matters

`GET /me/stories` returns only **currently live** stories, i.e. the last 24 hours **(verify)**.
A daily sync would miss stories posted and expired between runs. So:
- Poll `/me/stories` **every 6 hours** while the app is running (a cheap call: usually 0–5
  items). Feed media stays on the daily schedule.
- Stories that expired while the app wasn't running are only recoverable from the archive
  export. Say so in the UI: "Stories are captured while My Data Studio is running. Import your
  Instagram export to fill gaps."
- Highlights aren't exposed by this API **(verify)**. They come only from the export.

## Location

The Instagram API has **no** location, place or coordinate field. Meta's docs list the old
`location` / `latitude` / `longitude` fields as unsupported. So:
- API-synced posts have no geo point. Don't fake one from the caption.
- The **archive import** carries `media_metadata.photo_metadata.exif_data` with latitude and
  longitude on some media, even though the image file's own EXIF is stripped. When imported, it
  sets `files.latitude`/`longitude` (and the post's), which lights up `near:` and the map.
- Recommend a one-time archive import to professional-account users too, for exactly this
  reason. It's the only way their Instagram photos get onto the map.

## Archive import (all account types)

Kept from the earlier plan, now as the second path:
1. **Sample export first** (JSON, `locale_override=en_US`). Known shape **(verify)**:
   `your_instagram_activity/content/posts_1.json`, `stories.json`, `reels.json`; media under
   `media/posts/<YYYYMM>/…`; `creation_timestamp` in Unix seconds; optional
   `exif_data` coordinates. Commit a trimmed fixture.
2. **Text decoding:** Meta's exporter escapes UTF-8 as Latin-1 code points (`â\u0080\u0099` for
   `’`). Fix by re-encoding to Latin-1 bytes and decoding as UTF-8, in a shared
   `meta_export_text.dart` helper. Fixture test with emoji and accents.
3. **Parser** (pure Dart): posts and carousels, stories, reels → the same models the API path
   produces.
4. **Import isolate:** PST-style one-time isolate, writes via `writeViaMain()`. The UI offers it
   on the Instagram page ("Import Instagram export (.zip)"), and the Downloads watcher can pick
   up an `instagram-*.zip`.

## Embeddings

- Instagram is media-first, so **images carry most of the search value**. They're in `files`,
  so the existing `EmbeddingIsolate` already embeds and describes them.
- Post text embedding: `caption` + `alt_text` with the same prefix style as Facebook
  ("Instagram post, 2021-08-02: …"). Strip a trailing hashtag block before embedding, but keep
  hashtags in the FTS index, so `#banff` still matches by keyword.
- Posts with no caption get no text embedding. They're found through their images.

## The UI

Instagram is visual, so `InstagramPage` gets **two views** over the same data, with a toggle:
- **Grid** (default): 3-column square thumbnails, newest first, with month headers, sharing
  the Photos module's tile and thumbnail code. Carousel and reel badges in the corner. Tapping
  opens the post detail.
- **Feed:** the shared `SocialPostCard` (header, caption with linkified hashtags and mentions,
  media, "Open on Instagram"). No like or comment counts.
- **Post detail:** a carousel swiper over the post's files, using the Photos viewer. Caption
  below. Location chip when the archive supplied coordinates.
- **Stories strip** above the grid: past stories grouped by day, played back from local files.
- **Toolbar:** search scoped to `type:instagram`; filters for Reels, Carousels, Stories, a year
  picker; **On this day**.
- **States:** "Connect Instagram" (with the professional-account explanation),
  "Import export instead", backfill progress, "Reconnect Instagram", and "Video unavailable
  via API (licensed audio): import your export to fill it in".

## Dedupe with the camera roll (open question carried over)

Many Instagram photos are already in the library from the phone's camera roll or Google Drive,
in higher quality. Default: **link, don't delete**. When a perceptual hash or image-embedding
match is above a threshold, record `files.duplicate_of`, and have Photos show the original with
an "Also posted to Instagram" badge. Decide the threshold with real data. Out of scope for v1
if it slows delivery.

## Prerequisites (on top of Facebook's)

The Facebook plan's prerequisites (business verification, the Meta app, legal pages, the token
service) all apply and are done once. Instagram adds:
- [ ] Add the **Instagram** product (Business Login for Instagram) to the existing Meta app
- [ ] Register `https://auth.xdtlabs.com/instagram/callback` as a valid OAuth redirect URI
- [ ] Add `POST /instagram/exchange` to the token service. The Instagram app secret goes into
      Secret Manager next to the Facebook one (it may be a separate Instagram App Secret in the
      dashboard; **verify**)
- [ ] A professional (creator) test account with feed posts, a carousel, a reel and a live story,
      added as an Instagram tester in the dashboard
- [ ] Privacy policy updated to name Instagram
- [ ] App Review: `instagram_business_basic` Advanced Access, with its own recording

## Tests

- IG client against recorded fixtures: paging, a carousel with children, a reel without
  `media_url`, a story, `account_type = PERSONAL` rejected cleanly.
- Token refresh: refreshed when older than 30 days; not attempted before 24 hours; a lapsed
  token → `needs_re_auth`.
- Archive parser: carousel mapping, `exif_data` → lat/lng, mojibake decoding.
- Merge: the same post via API, then archive (and the reverse) gives one row, with location
  added by the archive and nothing duplicated.

## Done when

- A professional account connects, backfills every feed post, reel and carousel, and keeps
  syncing daily without the user doing anything. The token refreshes itself.
- Stories posted while the app is running are captured before they expire.
- A personal account can import its export and gets the same grid, feed and search.
- Archive-imported photos with coordinates appear on the map and match `near:`.
- Every photo and video appears in Photos with the post's date, carousels in order.
- A known caption is found by keyword, by hashtag and by `type:instagram`. A photo is found by a
  semantic query.

## Open questions

- Professional accounts and privacy: can a creator account stay private? This decides how hard
  we should point personal users at the API path versus the archive.
- Dedupe with the camera roll: in v1, or later?
