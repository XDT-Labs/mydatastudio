---
status: proposed
adr: none
remaining: [sample-export, export-parser, multi-blog, import-ui, api-phase-2]
---

# Plan: Archive Tumblr blogs

**Release order: 5.** Export first, with API sync as a later phase.

**Scope:** the user's own posts on each of their blogs, with drafts and private posts optional,
plus the uploaded media. Reblogs are kept **only** when the user added their own content, which
is the only part stored. Out of scope: likes, follows, messages, and other people's posts.

## Path 1: blog export (v1)

- **Settings › (choose blog) › Export** **(verify the path)**. Each blog is exported
  **separately**. Tumblr reportedly allows about **4 exports per blog per month** and keeps each
  for **3 days**. It emails when ready.
- Contents: a zip with **post HTML files**, the **uploaded media**, and XML of posts (and
  conversations, out of scope). It includes drafts, private and flagged posts, but not likes.
- **Parser:** posts from the XML (or per-post HTML), with type (text, photo, quote, link, chat,
  audio, video, answer), tags, date, and state (published, draft, private). Media is matched
  from the media folder into `files`. `external_id` = the Tumblr post id. `platform = 'tumblr'`,
  plus the blog name, so several blogs share one Tumblr page with a blog switcher.
- **UI:** the shared setup panel, with steps repeated per blog ("Export each blog you want to
  keep"), a file picker accepting several zips, and toggles for drafts and private posts
  (default on: they're the user's), with a re-export reminder.

## Path 2 (later): Tumblr API v2

- `GET /v2/blog/<blog>/posts?npf=true` (Neue Post Format JSON), paged by `before`/`offset`, with
  OAuth 2 for the user's own drafts and private posts. Tumblr's OAuth 2 token exchange may need a
  client secret **(verify)**. If so, use a bring-your-own app (as with Flickr) or the Cloud Run
  token service.
- Incremental: newest first, until a stored id. Rows merge with the export on the post id.

## Done when

A user imports each blog's export and gets every post (published, plus optionally drafts and
private) with media, tags and blog grouping, searchable and browsable per blog.
