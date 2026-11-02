---
status: proposed
adr: none
remaining: [shared-foundation, setup-ui, x-client, cost-estimate, incremental-sync, backfill, archive-import, media, places, embeddings, search, feed-ui]
---

# Plan: Sync X (Twitter) with the user's own API keys

The `social` module today is placeholder pages: `client/lib/modules/social/pages/twitter_page.dart`
renders a label, and `new_social_page.dart` shows a disabled "Login with Twitter" button. There is
no scanner, schema or import behind them.

This plan makes X work by **bringing your own developer app**. The user creates an app in the
X Developer Console, buys a little prepaid credit, and pastes their keys into My Data Studio. We
then load the posts they've sent, and keep them in sync daily. X bills the user directly, at the
cheap "owned data" rate. The free X archive download is offered as an optional, $0 way to
backfill the full history.

**Scope: an archive of what the user posted, not an X client.** That means the user's own posts
(including replies, quotes and long posts) and the media attached to them. Out of scope: DMs,
likes, bookmarks, other people's posts (except as a one-line "quoting @x" or "replying to @x"
reference), followers, and engagement counts. If the user didn't post it, we don't fetch it.

> Facts below were checked against X's developer docs on 2026-10-25. Items marked **(verify)**
> need a test against a real developer account.

## Does the X API allow this? Yes, with three caveats

Checked against [X's pricing](https://docs.x.com/x-api/getting-started/pricing) and endpoint docs:

1. **Bring-your-own-key is the model X prices for.** X API is **pay-per-use** (prepaid credits,
   no subscription, no minimum). The old Free/Basic/Pro tiers are gone. **Owned reads** (your
   own posts, when the `{id}` in the request *is* the authenticated user *and* that user owns the
   app) cost **$0.001 per post**, i.e. $1 per 1,000. Other post reads are $0.005, and user reads
   are $0.010. Re-reading the same post within one UTC day isn't billed twice. That only works if
   the **user owns the app and authenticates as themself**, which is exactly this design. A shared
   xdtlabs app would pay the 5× rate and carry everyone's bills.
2. **The user timeline only reaches the 3,200 most recent posts.** `GET /2/users/:id/tweets`
   returns "up to 3,200 most recent Posts", at the owned rate.
3. **Older posts need full-archive search.** `GET /2/tweets/search/all` with `from:<handle>` goes
   back to March 2006, up to 500 posts per request. It's open to pay-per-use. But it isn't one
   of the "owned" endpoints, so expect the standard **$0.005 per post** **(verify the actual
   billed rate)**. Search may also skip a protected account's posts **(verify)**.

**What that costs the user** (rough, before media):

| Account | Recent 3,200 (owned) | Older posts (search) | Total backfill | Then per month |
|---|---|---|---|---|
| 2,000 posts | $2 | — | **$2** | cents |
| 10,000 posts | $3.20 | 6,800 × $0.005 = $34 | **~$37** | cents |
| 50,000 posts | $3.20 | 46,800 × $0.005 = $234 | **~$237** | cents |

Hence the **archive option**: X's "Download an archive of your data" is free and complete, so
heavy posters can backfill from it and use the API only for the recent window and daily sync.
The setup UI shows this choice with the user's own numbers (see *Cost estimate*).

Other limits:
- A 3M post-read cap per billing cycle. Irrelevant for one person.
- Rate limits still apply on top of billing (`x-rate-limit-*` headers) **(verify the values)**.
- New accounts get small promotional credits ($20 after saving a card and buying credits once)
  that cover most backfills.

## What the user does (setup UI)

`twitter_page.dart` becomes `XPage`. Until it's connected, it shows a setup panel in the same
style as `MetaExportSetupPanel` (Facebook/Instagram plans): numbered steps, X's UI words in bold.

**1. "Create your X developer app"**
1. Click **Open X Developer Console** (`console.x.com` **(verify the URL)**). Sign in with the X
   account you want to archive. That account has to own the app for the cheap owned-data rate.
2. Accept the developer agreement, and create a **Project** and an **App**.
3. Under **Billing**, add a card and buy credits. **$5 is plenty for the recent 3,200 posts.**
   Set a **spending limit** so you can't be surprised.
4. Under the app's **Keys and tokens**, generate the **API Key and Secret** (consumer keys) and
   an **Access Token and Secret** for your own account, with **Read** permission.

**2. "Paste your keys"**: four masked fields (API Key, API Key Secret, Access Token, Access Token
Secret) and a **Test connection** button. The test calls `GET /2/users/me` (one user read,
$0.01), shows "Connected as @handle · 18,240 posts", and confirms the token belongs to that same
user.

**3. Cost estimate and backfill choice** (from `public_metrics.tweet_count`):
- ◉ **Recent posts via API** (≈ $3.20 for 3,200) **+ import my free X archive for the rest**
  (recommended when the count is over 3,200);
- ○ **Everything via API** (≈ $37; shows the arithmetic);
- ○ **Recent posts only** (≈ $3.20).

  "These charges go to your X developer account, not My Data Studio. Daily sync after that costs
  about $0.001 per new post."

**4. Optional: "Import your X archive"**: steps (**Settings › Your account › Download an archive
of your data**, confirm your password, wait for the email — X says it can take 24 hours or more,
then download the zip), plus a **Choose file…** field (`file_picker`, `.zip`), validated before
importing (it's an X archive, which account, date range). The parser is below.

**5. Sync status**: last sync, new posts, the X credit spent on API calls by this app (estimated
from the calls we made), and **Sync now**.

### Why the user's own access token (OAuth 1.0a), not an OAuth login

- The Developer Console generates an **access token and secret for the app owner's own account**.
  Those are OAuth 1.0a user-context credentials, which v2 endpoints accept ("UserToken") and
  which **don't expire**. Paste once, sync for years. No callback URL, no token refresh, no
  server.
- **OAuth 2.0 with PKCE** works too (X supports public clients, so no secret is needed). But the
  user would have to register an exact callback URL (a fixed `http://127.0.0.1:<port>/callback`)
  in their app, and the access tokens last ~2 hours with refresh tokens to rotate. That's more
  setup and more ways to break. Keep it as a fallback if X ever drops 1.0a **(verify 1.0a is
  still supported for v2 reads)**.
- An **app-only bearer token** can't be used: it isn't a user context, so reads wouldn't count as
  owned, and protected posts would be invisible.

**Storage of the keys:** all four go in `SecureVault` (`services/secure_vault.dart`: AES-GCM,
Argon2id-wrapped key), never in plain `collections` columns or logs. Reference them from the
collection by vault key. The scanner isolate receives the DEK via spawn args, as other isolates
already do.

## The X client

Pure Dart, in `modules/social/services/x/`. It signs requests with OAuth 1.0a (HMAC-SHA1; use a
maintained package or ~80 lines of our own, with tests against X's documented signature
examples).

- **Identify:** `GET /2/users/me?user.fields=id,username,name,protected,public_metrics,created_at`.
- **Timeline (owned rate):**
  `GET /2/users/:id/tweets?max_results=100&tweet.fields=id,text,created_at,
  conversation_id,in_reply_to_user_id,referenced_tweets,entities,attachments,geo,lang,
  note_tweet,edit_history_tweet_ids,possibly_sensitive&expansions=attachments.media_keys,
  geo.place_id,referenced_tweets.id,referenced_tweets.id.author_id&media.fields=media_key,type,
  url,preview_image_url,variants,alt_text,width,height,duration_ms&place.fields=full_name,
  country,geo&user.fields=username`. Follow `meta.next_token` until it runs out (≤3,200 posts).
  - The docs page for this endpoint currently names some fields `note_post` /
    `referenced_posts`, not `note_tweet` / `referenced_tweets`. **Verify the live names on the
    first real call**, and keep the field list in one constant.
  - Don't pass `exclude=replies`: the user's replies are their posts. Exclude retweets
    (`exclude=retweets`): a plain retweet is someone else's post. Quote posts are kept.
- **Older posts (full-archive search):** `GET /2/tweets/search/all?query=from:<handle>
  -is:retweet&max_results=500&end_time=<oldest timeline post>`, with the same fields, paging by
  `next_token`. Only when the user chose "Everything via API".
- **Long posts:** use `note_tweet.text` when present (the full text beyond 280 characters);
  `text` is truncated.
- **Edits:** an edited post gets a new id, and `edit_history_tweet_ids` lists every version.
  Store the **latest** version, keyed on the first id in the history, so an edit updates the row
  instead of adding one.
- **Media:** photo `url` and the highest-bitrate `video/mp4` in `variants` are public
  `pbs.twimg.com` / `video.twimg.com` URLs. Download them in the same pass. These downloads
  aren't API calls, so they aren't billed.
- **Places:** precise geotagging was removed from X years ago, so most posts have no `geo`. When
  `geo.place_id` is set, the expanded place gives `full_name` and a bounding box. Store its
  centre with `geo_precision = 'place'`. Exact coordinates (`geo.coordinates`) appear on old
  posts only.
- **Cost guard:** count billed resources per run, and stop at a per-run ceiling the user sets
  (default: the estimate + 20%). On HTTP 402 or a credit/spend-cap error, pause sync and show
  "Out of X credits — top up in the X Developer Console".
- **Rate limits:** on 429, wait until `x-rate-limit-reset`, and persist the wait across runs.

## Sync

A registered `CollectionScanner` (`XScanner`) in an isolate. Writes go through `writeViaMain()`
(single-writer rule), and resume state is in `social_sync_state`.
1. **Backfill**, per the user's choice: the timeline (≤3,200), then optional full-archive search
   back to the account's `created_at`. Save `next_token` after every page, so quitting midway
   resumes instead of re-paying.
2. **Incremental, daily** (plus app start): `GET /2/users/:id/tweets?since_id=<newest stored>`.
   A typical day is 0–20 posts, i.e. fractions of a cent. It needs the `ScannerManager` periodic
   trigger described in the Facebook plan.
3. **Edits:** an edited post comes back as a new id with `edit_history_tweet_ids`. The upsert on
   the original id replaces the stored version. No separate pass needed.
4. **Deletes:** don't poll for them. Re-listing costs money, and the archive keeps everything.
   **X's Developer Agreement asks apps to honour deletions (verify how it applies when the
   developer *is* the author, archiving their own posts).** If it applies, offer a setting:
   "Remove posts I delete on X" (default on), checked by a weekly id lookup of the last 30 days
   (`GET /2/tweets?ids=…`; owned **(verify)**). If it doesn't apply, keep everything and mark
   nothing.

## Archive import (optional, free backfill)

From the original plan. Use it when the user has more than 3,200 posts and doesn't want to pay
for search.
1. **Sample archive first.** Last known layout **(verify)**:
   - `data/tweets.js` (sometimes split across `tweets-part1.js` …), a JS file of the form
     `window.YTD.tweets.part0 = [ { "tweet": { … } }, … ]`. Strip the assignment prefix, then
     parse as JSON;
   - `data/tweets_media/` holds media named `<tweet_id>-<media_key>.<ext>`;
   - `data/account.js` uses the same wrapper (the account id, to check it matches the API user);
   - timestamps look like `Wed Oct 10 20:19:24 +0000 2018`, not ISO 8601.

   Commit a small trimmed fixture under `client/test/fixtures/`.
2. **Parser** (pure Dart): `full_text` with t.co links expanded from `entities.urls`; replies
   (`in_reply_to_status_id_str`); quotes; skip retweets (the `RT @` prefix); multi-part files;
   `edit_info` → latest version.
3. **Same ids as the API** (`id_str`), so archive rows and API rows merge on `(platform,
   external_id)` with no matching heuristics, unlike Meta's exports.
4. **Import isolate** in the style of the PST import, writing via `writeViaMain()`.
5. **Not schedulable.** X's archive is a one-time request (no recurring option, unlike Meta's
   EYI). That's fine: the API covers ongoing sync.

## Shared social foundation (built once, by whichever plan goes first)

These decisions apply to X, Facebook and Instagram. Record them as **ADR 0002**, because they're
schema-level and hard to reverse:

- **Schema:** one `social_posts` table with a `platform` column, rather than one table per
  platform:
  - columns: `id`, `collection_id`, `platform`, `external_id`, `kind` (post / reply / quote /
    story / reel / …), `text`, `story`, `created_at`, `thread_external_id`, `in_reply_to`,
    `url`, `place_name`, `latitude`, `longitude`, `geo_precision`, `link_url`, `link_title`,
    `raw_json`;
  - `social_posts_embeddings`, the same shape as `emails_embeddings`;
  - `imported_exports` (zip hashes) and `social_sync_state` (cursor, phase, newest/oldest seen).

  All declared in `AppDatabase.schemaDDL` with hand-written models under `models/tables/`, per
  the repo's no-codegen convention.
- **Media goes into `files`**, with `social_post_id` and `position`. Photos and videos then show
  up in the Photos module, with thumbnails, descriptions, image embeddings and clustering, and
  no social-specific work. `PhotoSource` gets a `socialPostId` to link back to the post.
- **Re-import is idempotent:** upsert on `(platform, external_id)`.
- **Search:** add a `social` value to `SearchResultType`, `type:social` plus per-platform
  aliases (`type:x`, `type:twitter`, `type:facebook`, `type:instagram`) in `SearchFilters`, a BM25
  (FTS5) index over `social_posts.text` and `place_name`, and a vector retriever over its
  embeddings, so `HybridRanker` merges social posts with email and file hits. `NearResolver`
  also searches `social_posts` lat/lng.
- **LLM tools:** `social` becomes another value of the `search` tool's `sources` argument
  (ADR 0001), not a new tool.
- **UI:** a platform-agnostic `SocialPostCard` and paged feed list, shared by all three pages.
- **Embeddings:** generalize `EmailEmbeddingIsolate` into a text-row embedder that takes a table.

## X-specific storage notes

- `external_id` = the post id (`id_str`); for edited posts, the first id in
  `edit_history_tweet_ids`.
- `kind`: `post`, `reply`, `quote`, `thread` (a reply to the user's own post, same
  `conversation_id`).
- `text` = the full text (from `note_tweet` when present), with t.co links expanded from
  `entities.urls`. Keep the expanded URL list in `raw_json` for link cards.
- `in_reply_to` = the parent id, plus the `@username` of the replied-to or quoted author (from
  the expansion). We store a name and an id, never the other person's post text.
- `url` = `https://x.com/<handle>/status/<id>`.

## Embeddings and search

- Text embedding per post: full text with a short prefix ("X post, 2017-03-02: …"), and the
  place name when there is one. Threads: also embed the concatenated thread as one extra chunk on
  the root post, so "that thread I wrote about Rust" finds it.
- Media: in `files`, so the existing `EmbeddingIsolate` already embeds and describes it.
- Search: shared foundation, with `type:x` / `type:twitter`.

## The feed UI

`XPage`, once connected:
- **List:** the shared feed (paged `ListView.builder`, newest first, month/year headers, year
  jump bar).
- **`SocialPostCard` for X:**
  - header: @handle, date, "Replying to @x" / "Quoting @x";
  - body: text with linkified URLs, @mentions and #hashtags;
  - media: a 1–4 image grid or a video poster, opening the Photos viewer;
  - **threads:** collapsed under the root post with "Show thread (6)";
  - footer: "Open on X". No like, repost or view counts.
- **Toolbar:** search scoped to `type:x`, filters (Has media, Replies, Threads, a year picker),
  **On this day**, and a gear for keys, sync and cost settings.
- **States:** setup panel; backfill progress with the running cost; "Out of X credits";
  "Keys rejected — check your app in the X Developer Console"; rate-limited until <time>.

## Tests

- OAuth 1.0a signing against X's documented example signature.
- Client against recorded fixtures (scrub ids and text): timeline paging, a long post
  (`note_tweet`), an edited post, a quote and a reply, media with video variants, a place
  expansion, the 3,200 cutoff, 402/credit errors, 429 with reset.
- Cost estimator: posts ≤3,200 → owned only; more → the three options with correct totals.
- Sync: a backfill interrupted mid-page resumes from `next_token`; `since_id` incremental adds
  only new posts; an edit replaces the row, it doesn't add one.
- Archive parser: `window.YTD` prefix stripping, multi-part files, t.co expansion, retweets
  skipped. Archive + API for the same post gives one row.
- Keys: stored in `SecureVault`, never in logs or `collections` plaintext.

## Done when

- A user follows the on-page steps, pastes four keys, sees a cost estimate with their own post
  count, and backfills. Posts and media appear, at about the estimated cost.
- New posts appear within a day, unattended, at fractions of a cent per day.
- A heavy poster backfills from the free archive, and archive and API posts merge without
  duplicates.
- Media appears in Photos. A known post is found by keyword, by a semantic query and by
  `type:x`.
- Credit exhaustion, bad keys and rate limits show a visible state, never silent failure.

## Open questions

- Deletions: does X's Developer Agreement require removing posts the user deleted, when the user
  is both the developer and the author? Decide the default for the "Remove posts I delete on X"
  setting after reading the agreement.
- Default backfill choice when the count is over 3,200: archive + API (cheapest, slower: the
  archive takes a day or more), or everything via API (fast, costs money)? Proposal: recommend
  archive + API, but show both prices.
