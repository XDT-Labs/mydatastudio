---
status: proposed
adr: none
remaining: [sample-export, parser, image-fetch, import-ui]
---

# Plan: Archive Pinterest boards and pins

**Release order: 5.** Export only. The Pinterest API (v5) needs app approval that developers
report as slow and inconsistent ("trial access pending" for weeks), so it isn't worth it for a
personal archive.

**Scope:** the user's **boards**, and the **pins on them**: both pins the user created
(uploads) and pins they saved. Boards are the user's own curation, so saved pins count. Each
pin is stored as image + link + the user's note, not as someone else's post. Out of scope:
messages, followers, search history, comments.

## The export

- Pinterest **Settings › Privacy and data › Request your data** (or **Data and privacy ›
  Download your data**) **(verify the path)**. Pinterest emails a link when it's ready.
- Contents per guides: profile, boards, pins, comments, messages, search history and settings.
  The export **may not include full-resolution images**. Record the real layout from a sample
  export **(verify)**.

## Import

- **Boards** → `albums`, keeping the board name and description; secret boards are flagged.
- **Pins** → `social_posts` (`platform = 'pinterest'`, `kind = pin`: `text` = the pin
  note/description, `link_url` = the pin's source link, `created_at` = the date saved) plus the
  pin image in `files`, linked to the board's album.
- **Images:** use the export's images where present. Otherwise download the pin image URL from
  the export (`i.pinimg.com`, preferring the `originals/` size **(verify)**). Failures keep the
  pin with its link.
- **Search:** pin notes and board names are embedded as text, and images through the existing
  `EmbeddingIsolate`. "That kitchen idea I pinned" should find it by image content.
- **UI:** the shared setup panel and file picker. The Pinterest page is a masonry grid per
  board. Re-export reminder (no scheduling).

## Done when

A user imports the export and sees every board as an album, with its pins' images and links,
searchable by note and by image content.
