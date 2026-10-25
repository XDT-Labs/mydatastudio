---
status: proposed
adr: none
remaining: [sample-export, csv-parser, media-fetch, import-ui, api-phase-2]
---

# Plan: Archive Reddit posts and comments

**Release order: 5.** Export first. An optional personal API app comes later, for incremental
sync.

**Scope:** the user's own **posts** and, as an **opt-in**, their own **comments**. On Reddit,
comments are most of what people write, so the "no comments on others' posts" rule from
Facebook is relaxed here as a user choice, with only the user's own words stored. Out of scope:
votes, saved items, messages and chats, subscriptions, and other people's content (a comment
is shown with its subreddit and a link to the thread, never the thread itself).

## Path 1: data request export (v1)

- **reddit.com/settings/data-request** › request the data. It arrives within minutes to a few
  days (sources vary); download from the email or link.
- Contents (CSV): **`posts.csv`** (id, permalink, date, subreddit, title, url, body, …) and
  **`comments.csv`** (id, permalink, date, subreddit, body, parent, …), plus files out of scope
  (votes, saves, messages). **Content deleted before the export isn't included.** Record the
  real columns from a sample export **(verify)**.
- **Parser:** the `csv` package (added by the LinkedIn plan). `external_id` = the Reddit
  fullname (`t3_…` for posts, `t1_…` for comments); `kind` = `post`, `link`, `image` or
  `comment`. Bodies are Markdown: render them in the card, and strip them to text for embedding.
- **Media:** for image and gallery posts, `url` points at `i.redd.it` / `v.redd.it`. Download
  the image into `files`. Video (`v.redd.it`) needs its DASH manifest; v1 only does images,
  linking the rest.
- **UI:** the shared setup panel (steps, **Open Reddit data request**, file picker with
  validation: "Reddit export · 214 posts · 3,902 comments"), a **"Include my comments"** toggle,
  and a re-export reminder (no scheduling).

## Path 2 (later): personal API app

- The user creates their own app at **reddit.com/prefs/apps**. Use an **installed app**
  (OAuth with a loopback redirect, no secret) rather than a "script" app, because a script app
  would mean typing the Reddit password into our app. Free for personal use, about 100 queries
  per minute **(verify the current terms)**.
- `GET /user/<name>/submitted` and `/user/<name>/comments`, newest first, until a stored id.
  **Listings stop at about 1,000 items**, so the export stays the backfill and the API only
  keeps it current.

## Done when

A user imports the export and gets every surviving post (and, if chosen, every comment) with
images, searchable and grouped by subreddit. Re-importing a newer export only adds what's new.
