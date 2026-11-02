---
status: proposed
adr: none
remaining: [sample-exports, goodreads, letterboxd, medium, substack, import-ui]
---

# Plan: Quick file imports: Goodreads, Letterboxd, Medium, Substack

**Release order: 6** (alongside Strava). Each of these offers a simple export of what the user
wrote or logged. None needs an API. One plan, because they share everything except a small
parser each. Uses the shared setup panel, file picker, `csv` and `archive` packages,
`imported_exports`, `social_posts` and search.

| Service | Export | What we keep | `kind` |
|---|---|---|---|
| **Goodreads** | **My Books › Import and export › Export Library** → `goodreads_library_export.csv` **(verify it's still offered)** | Books read, shelves, the user's rating, **the user's review text**, dates read | `book` / `review` |
| **Letterboxd** | **Settings › Data › Export your data** → a zip of CSVs (diary, reviews, ratings, watched, lists) **(verify the file names)** | Diary entries with dates, ratings, **review text**, lists | `film` / `review` |
| **Medium** | **Settings › Security and apps › Download your information** → a zip whose `posts/` folder has one HTML file per story **(verify)** | Stories the user wrote (drafts optional) | `article` |
| **Substack** | **Dashboard › Settings › Exports › Create new export** → a zip with `posts.csv` and per-post HTML **(verify)** | Posts the user published (subscriber lists are out of scope) | `article` |

## Import and storage

- `social_posts` with `platform` = `goodreads` / `letterboxd` / `medium` / `substack`.
  `external_id`: the Goodreads Book Id + read date, the Letterboxd URI, or the Medium/Substack
  post slug or id.
- **Reviews and logs:** `text` = the user's review, with the book/film title, author/director,
  rating and date in structured columns (`raw_json` + `link_title`). Only the user's own words
  and ratings; no other people's reviews.
- **Articles:** HTML → text with `html_text_extractor.dart`, chunked like LinkedIn articles for
  embeddings, original HTML kept for an offline reader view. Images referenced in articles are
  downloaded into `files` where the URLs still work.
- **Search:** "that book I gave five stars in 2019", "my review of Dune", "what I wrote about
  remote work" all work through FTS and embeddings. `type:goodreads`, `type:letterboxd` etc.
  map to platforms.

## UI

One **"More imports"** section on the New Social Source page, with a card per service. Each has
its export steps, an **Open settings** button and the file picker, validated by detecting the
service from file names and headers. Views:
- a **Reading** shelf (Goodreads) and a **Watching** diary (Letterboxd): covers fetched from
  the export's URLs when present (else a title tile), grouped by year;
- Medium and Substack articles in the shared **Articles** list used by LinkedIn.

## Done when

Each of the four imports from a real export, re-imports without duplicates, and is searchable
by title, the user's review text, and date.
