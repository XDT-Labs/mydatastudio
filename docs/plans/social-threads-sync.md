---
status: proposed
adr: none
remaining: [export-spike, export-import, scheduled-export, threads-api-deferred, ui]
---

# Plan: Archive Threads

**Release order: 2.** Threads is Meta's, so it slots into the Facebook/Instagram machinery:
- export-first through Meta's Export Your Information (EYI);
- the Threads API is **deferred until business verification**, exactly like Facebook's Graph API.

**Scope:** the user's own threads, replies, quote posts and carousels, with media. Out of scope:
reposts, likes, followers, DMs, other people's posts and engagement counts.

Reuses [social-facebook-sync.md](social-facebook-sync.md) and
[social-instagram-sync.md](social-instagram-sync.md): the export setup panel, file picker
validation, Drive handoff, `imported_exports`, `meta_export_text.dart` (mojibake fix) and
`SocialPostCard`. `platform = 'threads'`.

## Path 1: Meta export (v1)

- Threads app: **Settings › Account › Download your information**, which opens Accounts Center
  EYI **(verify)**. Choose the Threads profile, **JSON**, **All time**, **High** quality.
- **Spike** (alongside the Meta spike):
  - Is Threads a separate `account_type` in the EYI deep link, or part of the Instagram export
    (Threads profiles are tied to Instagram accounts)?
  - Can it be **scheduled to Google Drive** like Facebook and Instagram?
  - What's the layout (`your_threads_activity/…`?), and is there location data?
- If schedulable: the same daily, 3-year schedule and renewal reminder as Instagram. If not: a
  re-export reminder.
- Parser: posts and carousels → `social_posts` + `files`. Identity from the post's media URI and
  timestamp hash (Meta exports have no API ids; verify).

## Path 2: Threads API (deferred until business verification)

Research kept for later:
- Host `graph.threads.net` (or `graph.threads.com`). Permission **`threads_basic`** ("required
  for making any calls to all Threads API endpoints"). Getting it for users who aren't app
  testers needs App Review **(verify; expect business verification, as on Facebook)**.
- `GET /me/threads?fields=id,media_type,media_url,permalink,text,timestamp,children,is_quote_post,shortcode`,
  paged with `paging.cursors` / `since` / `until`. **No location field.** Note Meta's display
  rule: posts may be shown "solely to the person who created it", which matches a private
  archive.
- Tokens: a 1-hour token → a 60-day long-lived token (needs the app secret → the Facebook plan's
  Cloud Run token service). Then `GET /refresh_access_token?grant_type=th_refresh_token`, which
  works from 24 hours old until expiry (no secret), so the client keeps it alive indefinitely.
  Permissions from **private** profiles last 90 days.
- Build on the shared `MetaGraphClient` / `MetaSocialScanner`.

## Done when

A Threads user follows the on-page steps, picks the export, and gets every thread with media,
merged without duplicates on re-import. Plus scheduled updates, if the spike shows Threads
exports can be scheduled.
