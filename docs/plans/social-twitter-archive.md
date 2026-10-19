---
status: proposed
adr: none
remaining: [sample-export, shared-foundation, parser, import-isolate, ui, search, embeddings]
---

# Plan: Import a Twitter / X archive

The `social` module today is placeholder pages: `client/lib/modules/social/pages/twitter_page.dart`
renders a label, and `new_social_page.dart` shows a disabled "Login with Twitter" button. There is
no scanner, schema or import behind them.

This plan replaces the login button with a **one-time archive import**. The user downloads their
archive from X ("Settings › Your account › Download an archive of your data"), picks the `.zip`,
and we import tweets, media and (optionally) DMs into the local database.

## Why archive import, not the API

The X API's free tier doesn't give a user their own full history, and the paid tiers are priced
for businesses. The archive is complete, free, works offline, and matches the app's local-first
model. **Verify this against current X API terms before building**; it has changed several times.

## Build this one first

Of the three social plans, this is the simplest export format and the best one to build the
**shared social foundation** (below) on. Facebook and Instagram then reuse it.

## Shared social foundation (built once, by whichever plan goes first)

These decisions apply to all three platforms. Settle them here and record them as an ADR
(probably ADR 0002), because they're schema-level and hard to reverse:

- **Schema:** one `social_posts` table with a `platform` column, rather than one table per
  platform. Probable columns: `id`, `collection_id`, `platform`, `external_id`, `kind`
  (post / reply / repost / story / message), `text`, `created_at`, `thread_external_id`,
  `in_reply_to`, `url`, `raw_json`. Plus `social_posts_embeddings` (same shape as
  `emails_embeddings`). Declared in `AppDatabase.schemaDDL` and a hand-written model under
  `models/tables/`, per the repo's no-codegen convention.
- **Media goes into `files`**, linked from the post. Photos and videos then show up in the Photos
  module, get thumbnails, descriptions and image embeddings, and are clustered by the existing
  code with no social-specific work.
- **Import runs like the PST import** (`outlook_pst_scanner_isolate.dart`): a one-time isolate the
  UI starts directly, not a registered scanner. It reads the zip and sends every write to the
  main isolate with `writeViaMain()`, following the single-writer rule.
- **Re-import is idempotent:** upsert on `(platform, external_id)`, so importing a newer archive
  adds what's new without duplicating anything.
- **Search:** add a `social` value to `SearchResultType`, a `type:social` alias in
  `SearchFilters`, a BM25 (FTS5) index over `social_posts.text`, and a vector retriever over its
  embeddings, so `HybridRanker` merges social posts with email and file hits.
- **LLM tools:** `social` becomes another value of the `search` tool's `sources` argument
  (ADR 0001), not a new tool.

## Twitter-specific work

1. **Sample export first.** Get a real, recent archive and write down its layout before writing
   the parser. As of the last known format:
   - `data/tweets.js` (sometimes split across `tweets-part1.js` …): a JS file of the form
     `window.YTD.tweets.part0 = [ { "tweet": { … } }, … ]`. Strip the assignment prefix, then parse
     as JSON.
   - `data/tweets_media/` holds media named `<tweet_id>-<media_key>.<ext>`.
   - `data/direct-messages.js`, `data/like.js` and `data/account.js` use the same wrapper.
   - Timestamps look like `Wed Oct 10 20:19:24 +0000 2018`, not ISO 8601.
   
   Commit a small trimmed fixture under `client/test/fixtures/` for tests.
2. **Parser** (pure Dart, no I/O): turns the archive entries into `SocialPost` models. It
   handles:
   - `full_text` with t.co links expanded from `entities.urls`;
   - replies (`in_reply_to_status_id_str`);
   - retweets (the `RT @` prefix);
   - quote tweets;
   - multi-part `tweets-partN.js` files.
3. **Import isolate**, following the PST import pattern.
4. **UI:**
   - replace the disabled login button with "Import Twitter archive (.zip)";
   - show progress (posts and media counts);
   - `twitter_page.dart` becomes a reverse-chronological timeline with search.
5. **Embeddings:** text embedding of the post body. Whether that's a new isolate or a generalized
   `EmailEmbeddingIsolate` is a decision for the shared-foundation ADR.

## Open questions

- Import DMs at all? They're private conversations with other people. Default off, opt-in
  separately?
- Import likes? They're other people's tweets, and `like.js` contains only ids and text, no
  author or media.
- Deleted or protected tweets in the archive: keep them, and mark them?

## Done when

- Importing a real archive creates one post per tweet. Re-importing the same archive changes
  nothing.
- Media from the archive shows up in Photos and gets a thumbnail.
- `type:social` search and a plain keyword search both find a known tweet. A semantic query finds
  it once its embedding is built.
- Tests: the parser against the fixture (including a multi-part file and a quote tweet), and
  re-import idempotency against a seeded database.
