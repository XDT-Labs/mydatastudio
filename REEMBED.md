# Regenerating the embeddings

Every vector written before `7ac9c99` came from a randomly-initialised model
(see that commit). They are noise, and because the random initialisation
differed on every launch of the AI subprocess, vectors written in one app
session were never comparable with another's. There is nothing to salvage.

**You no longer delete anything.** Each vector now records which pipeline built
it (`EmbeddingModel.current`), and the embedding isolates treat anything else —
including the `NULL` every existing row gets when the column is added — as work
to redo. Adding the column *is* the migration.

## What to do

**1. Build the Python service from this branch.**

```bash
cd /Users/mikenimer/Development/github/mydatatools-desktop/.claude/worktrees/multi-modal-search-plan-8a7d8f && make build-python && make local-install-python
```

The checkout matters and is easy to get wrong: the loader fix lives on
`claude/multi-modal-search-plan-8a7d8f`, **not** on `develop`. Building from
`develop` produces a binary with the original bug, and the rebuild would then
refill the archive with fresh noise — indistinguishable from success.

Verify before going further. The fixed loader raises rather than serving noise,
so a service that starts cleanly is a service that loaded its weights. It must
not print `newly initialized` at startup.

**2. Relaunch the app.** That is the whole migration. The column appears, every
existing row reads as unknown, and the isolates start refilling them.

Nothing else needs clearing. The AI **descriptions** on `files.description`
come from the chat model, not the embedding model, and are unaffected — which
matters, because they are the expensive artifact and they are what the
description embeddings are computed *from*. Keyword search over them keeps
working throughout.

## What it costs

| | Count | Rate | Estimate |
|---|---|---|---|
| Descriptions (text) | 2,338 | 0.28 s each | ~11 min |
| Emails (text) | 1,279 | 0.28 s each | ~6 min |
| Images (vision) | 2,373 | 3.8 s each | ~2.5 hours |

Description vectors are rebuilt **first**, deliberately. They are text, so a
batch costs seconds rather than minutes — and the description vector is the
stronger signal for a text query, beating the image vector on 44 of 45 photos
measured against this archive. Search is largely back on its feet within the
first twenty minutes, while the image pass grinds on behind it.

The image figure already includes the resolution bound in `VisionImage`.
Without it the same six sample photos took 10.9 s each rather than 3.8 s, which
would have made this a 7.2-hour pass. Worth knowing where that saving comes
from, because the obvious explanation is wrong: Qwen-VL's processor caps its
own input at `max_pixels` (~1.3 MP), so a 20 MP photo was never costing the
vision tower 20 MP of work. The cost was base64-encoding a 12 MB JPEG, pushing
it through a JSON body, and decoding it again — the sample payload fell from
47,964 KB to 912 KB.

The rebuild is incremental and resumable, and search degrades gracefully while
it runs: a file whose vector has not been rebuilt yet is simply absent from the
semantic pass and stays fully reachable by keyword.

## Checking it worked

```bash
sqlite3 ~/Library/Application\ Support/com.xdtlabs.mydatastudio.dev/data/mydata.db "SELECT model_version, COUNT(*) FROM files_embeddings GROUP BY 1;"
```

Rows still showing `NULL` are still pending. When they are all stamped
`Qwen/Qwen3-VL-Embedding-2B@2`, the rebuild is done.

Then search `family photos`. Before the fix that query returned mountain goats
and wallpaper marketing mail; on a re-embedded sample of 220 real photos it
returns, in order, a family with two young children in stadium seats, a group
of five including children in the snow, and four people posing at a decorated
hedge wall.

## If this happens again

Bump `EmbeddingModel.revision`. Anything that changes what the vectors *mean* —
a different checkpoint, different pooling, a new prompt template, another
loader fix — makes old vectors incomparable with new ones, and the revision is
what tells the isolates so. No SQL, no manual delete, no way to forget.
