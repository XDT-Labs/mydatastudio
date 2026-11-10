---
status: proposed
adr: none
remaining: [sample-export, csv-and-zip-deps, export-parser, media-fetch, import-isolate, setup-import-ui, reexport-reminder, embeddings, search, feed-ui]
---

# Plan: Archive LinkedIn posts from the data export

> **Needs a real export before implementation.** The CSV columns, date format, and whether
> media links still download are all unconfirmed (marked **(verify)**). Request a real export
> first, record its layout here, and adjust the parser section before writing code.

There's no LinkedIn placeholder in the `social` module yet. This plan adds a `LinkedInPage`,
using the same setup-panel and feed pattern as the [Facebook](social-facebook-sync.md),
[Instagram](social-instagram-sync.md), [X](social-x-sync.md) and
[TikTok](social-tiktok-archive.md) plans.

**Export only.** LinkedIn's APIs that can read a member's own posts are either closed to new
developers or limited to EEA and Swiss members (the DMA portability APIs), so they're ignored
for now. Revisit if that changes.

**Scope: an archive of what the user posted, not a LinkedIn client.** That means the user's own
posts (with any commentary they added when reposting), their articles, and the images and
documents attached to them. Out of scope: messages, connections, comments (including comments
the user left on others' posts), reactions, profile and résumé data, job applications, and
engagement counts.

> Facts below were checked against third-party guides on 2026-10-25. LinkedIn's own help pages
> didn't surface in research, so treat every detail as **(verify)** until a real export confirms
> it.

## How the export works

In LinkedIn: **Me › Settings & Privacy › Data privacy › Get a copy of your data**
(`https://www.linkedin.com/mypreferences/d/download-my-data` **(verify)**).
- Choose **Download larger data archive** (the full archive). The "something in particular"
  checkboxes may not include posts **(verify which option yields `Shares.csv`)**.
- Click **Request archive** and re-enter the password.
- LinkedIn emails when it's ready: about **24 hours**, up to 48. A smaller "first instalment"
  zip may arrive within minutes, without posts **(verify)**.
- The download is available for **72 hours**.
- Format: a zip of **CSV** files (not JSON). Posts are in **`Shares.csv`**. Articles are in an
  `Articles/` folder, probably as HTML files **(verify)**.
- **No scheduling.** It's a one-time request each time, unlike Meta's recurring exports.

## Setup and import UI (on the LinkedIn page)

`LinkedInPage` shows this until the first import finishes. After that, it lives behind a
sync-settings gear. It's the shared setup-panel widget from the Meta plans, parameterised for
LinkedIn.

**1. "Export your LinkedIn data":** numbered steps, with LinkedIn's UI words in bold:
1. Click **Open LinkedIn data settings** (opens the page above in the user's browser).
2. Choose **Download larger data archive**, click **Request archive**, and enter your password.
3. LinkedIn emails you when it's ready, usually within 24 hours. If you get a smaller first file
   quickly, wait for the second, complete one: that's the one with your posts.
4. Download it within 72 hours.

Next to the steps: "What gets imported" (posts, reposts with your commentary, articles, attached
images and documents) and the out-of-scope list (messages, connections, comments, profile).

**2. "Choose your export":** a read-only path field with **Choose file…** (`file_picker`,
`.zip`) and **Choose folder…** for an already-unzipped export. Validate before importing:
- a LinkedIn export containing `Shares.csv` → "LinkedIn export · 412 posts · Jan 2014 – Oct 2026";
- a LinkedIn export **without** `Shares.csv` (the quick first instalment) → "This is the
  partial export. Wait for LinkedIn's second email with the complete archive";
- another platform's export → "This looks like a Facebook / Instagram / X export", with a button
  to switch pages.

**3. Import** with progress (posts parsed, media downloaded, articles). Media links that fail are
listed, with a note that the text was still archived.

**4. "Keep it up to date":** LinkedIn can't schedule exports, so offer a **re-export reminder**
(monthly by default; off, monthly or quarterly). The reminder reopens step 1. Re-importing a
newer export only adds what's new.

**5. Sync status:** last export imported, posts added, "next reminder on <date>",
**Import another export…**.

## Parsing the export

1. **Sample export first.** Record the real column headers of `Shares.csv`. Expected
   **(verify)**: `Date`, `ShareLink`, `ShareCommentary`, `SharedUrl`, `MediaUrl`, `Visibility`.
   Also record:
   - the date format (`YYYY-MM-DD HH:MM:SS`, and in which time zone?);
   - how multi-line commentary is quoted;
   - whether there's a preamble line before the header (some LinkedIn CSVs start with notes);
   - the `Articles/` layout.

   Commit a trimmed fixture under `client/test/fixtures/`.
2. **Dependencies:** the client has no zip or CSV reader today. Add **`archive`** (zip; the Meta,
   X and TikTok importers need it too, so add it once) and **`csv`** (RFC 4180 with multi-line
   quoted fields), or a small parser of our own with tests. Don't split on commas: commentary
   contains commas, quotes and newlines.
3. **Parser** (pure Dart). Locate files by name pattern, case-insensitive, so a rename fails
   loudly instead of silently importing nothing.
   - **Each `Shares.csv` row** → one `social_posts` row (`platform = 'linkedin'`):
     - `text` = `ShareCommentary`, unescaped (LinkedIn may export its own mention and hashtag
       markup; strip it to plain text **(verify)**);
     - `created_at` from `Date`;
     - `url` = `ShareLink`;
     - `link_url` = `SharedUrl`;
     - `privacy` = `Visibility`.
   - **`kind`:**
     - `post`: commentary, no shared LinkedIn post;
     - `repost`: commentary plus a `SharedUrl` pointing at another LinkedIn post. Kept: the
       commentary is the user's;
     - `link`: commentary plus an external `SharedUrl`.

     A plain repost with **no** commentary is someone else's post: skip it, as with X
     retweets.
   - **`external_id`:** the activity id from `ShareLink` (`urn:li:activity:<id>` or the
     numeric id in the URL), which should be stable across exports **(verify)**. Fallback: a
     hash of `(Date, ShareCommentary)`.
   - **Articles:** one row per article (`kind = article`): title, publish date, and the body
     converted from HTML to text with the existing `html_text_extractor.dart`. The original HTML
     is kept in `raw_json` for rendering.
4. **Media fetch:** `MediaUrl` points at LinkedIn's CDN (`media.licdn.com`). Download each one
   during import as a `files` row with `social_post_id`, so images land in Photos. These URLs
   are likely signed and may expire within days of the export **(verify)**, which is one more
   reason to import promptly. PDFs and slide documents go into `files` as documents (unified
   search's document extraction then indexes them). If a URL fails, keep the post and list the
   failure. Never fetch behind a LinkedIn login.
5. **Import isolate:** in the style of the PST import. Writes via `writeViaMain()`
   (single-writer rule). Unzip to a temp dir, record the zip hash in `imported_exports`, and
   upsert on `(platform, external_id)`, so re-importing is a no-op.

## Storage, embeddings and search

From the shared social foundation ([social-x-sync.md](social-x-sync.md), ADR 0002):
- `social_posts` with `platform = 'linkedin'`; media and documents in `files`
  (`social_post_id`, `position`).
- **No location:** LinkedIn posts carry none. Nothing for `near:`.
- **Embeddings:** post commentary with a prefix ("LinkedIn post, 2022-04-11: …"). Articles are
  long, so chunk them with the email chunker and embed each chunk. That makes "what did I write
  about hiring?" find the right paragraph. Images and documents go through the existing
  `EmbeddingIsolate` and document extraction.
- **Search:** `type:linkedin` (plus `type:social`), FTS5 over commentary, article titles and
  bodies, and `social` as an LLM `search` source.

## The UI

`LinkedInPage`, once imported:
- **Feed:** the shared `SocialPostCard`:
  - commentary with linkified URLs;
  - for reposts, a quoted "Reposted a post" stub linking to `SharedUrl` (never the other
    person's content);
  - a link card for external URLs;
  - an image grid or document thumbnail;
  - "Open on LinkedIn".

  No reaction or comment counts.
- **Articles tab:** a list of articles (title, date, first lines). Opening one shows a reader
  view rendered from the stored HTML, offline.
- **Toolbar:** search scoped to `type:linkedin`, filters (Posts, Reposts, Articles, Has media, a
  year picker), **On this day**, and the settings gear.
- **States:** the setup panel; import progress; "Partial export: wait for the complete one";
  "Reminder: export again to pick up new posts".

## Tests

- CSV parsing against the fixture: multi-line quoted commentary, embedded quotes and commas, an
  optional preamble line, the date format.
- Kind mapping: post vs repost-with-commentary vs link; a plain repost with no commentary is
  skipped.
- Identity: the same post in two exports gives one row; the fallback hash works when
  `ShareLink` is missing.
- Validation: partial export detected; another platform's export detected.
- Articles: HTML → text, chunked embeddings.
- Media: a failed `MediaUrl` keeps the post and is reported.

## Done when

- A user follows the on-page steps, picks the complete export, and gets every post and article
  they wrote, with images and documents where the links still work. Re-importing changes
  nothing.
- Re-exporting months later adds only the new posts.
- Posts and article paragraphs are found by keyword, by a semantic query and by
  `type:linkedin`.
- A partial export, or a reminder that's due, shows a clear state, never silent failure.

## Open questions

- Profile and résumé data (positions, education, skills) are what LinkedIn is most used for.
  Out of scope as "not a post", but would a "My career" view be worth a separate plan?
- Default reminder cadence: monthly or quarterly? LinkedIn posting is usually infrequent.
