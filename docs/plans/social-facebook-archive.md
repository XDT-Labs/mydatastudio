---
status: proposed
adr: none
remaining: [sample-export, parser, import-isolate, ui, messenger-decision]
---

# Plan: Import a Facebook archive

`client/lib/modules/social/pages/facebook_page.dart` is a placeholder label, and
`new_social_page.dart` shows a disabled "Login with Facebook" button. There's nothing behind
either.

This plan replaces the login with a **one-time import** of the user's "Download Your Information"
export (Accounts Center › Your information and permissions › Download your information),
requested in **JSON** format, not HTML.

## Why archive import, not the Graph API

Reading a user's own full post history through the Graph API requires the `user_posts`
permission and app review, and it doesn't cover Messenger. The export is complete and offline.
**Verify against current Meta platform terms before building.**

## Depends on

The **shared social foundation**: `social_posts` schema, media in `files`, PST-style import
isolate, idempotent upsert, search and LLM-tool integration. It's defined in
[social-twitter-archive.md](social-twitter-archive.md). Build it there first, or here if Facebook
goes first. The decisions are the same either way.

## Facebook-specific work

1. **Sample export first.** The folder layout changes between export versions, so record a real,
   recent one before writing the parser. Known shape (verify):
   - `your_facebook_activity/posts/your_posts__check_ins__photos_and_videos_1.json` (numbered
     `_1`, `_2`, … for large accounts);
   - `your_facebook_activity/messages/inbox/<thread>/message_1.json`;
   - media referenced by relative `uri` paths into the export;
   - Unix-second `timestamp` / `creation_timestamp` fields.
   
   Commit a small trimmed fixture for tests.
2. **Text decoding.** Facebook's JSON export is known to escape UTF-8 bytes as if they were
   Latin-1 code points (`â\u0080\u0099` instead of `’`). The parser must re-encode those
   strings to Latin-1 bytes and decode them as UTF-8, or every accented character and emoji is
   garbled. A fixture test must cover it.
3. **Parser** (pure Dart): posts, check-ins (place name, plus coordinates when present, so
   `near:` can use them), photos and videos with captions, and shared links. Locate files by
   pattern rather than hard-coded paths, so a layout change fails loudly and visibly rather than
   silently importing nothing.
4. **Import isolate, UI, embeddings:** same as the shared foundation. `facebook_page.dart` becomes
   a timeline with search.

## Open questions

- **Messenger:** often the largest and most valuable part of the export, but it's other people's
  messages. Import into `social_posts` with `kind = message`, or treat Messenger threads like
  email threads (closer to the email module's model)? This affects the shared schema, so decide
  before building.
- Comments the user left on other people's posts are exported without the post they reply to.
  Import them as standalone items, or skip them?
- Should check-in coordinates feed the `places` gazetteer used by `near:`?

## Done when

- Importing a real export creates one post per Facebook post, with correctly decoded text
  (emoji and accents intact). Re-importing changes nothing.
- Photos from the export appear in the Photos module.
- A known post is found by keyword search, by `type:social`, and by `near:` for a check-in.
- Tests: mojibake decoding, numbered `_N.json` files, and import idempotency.
