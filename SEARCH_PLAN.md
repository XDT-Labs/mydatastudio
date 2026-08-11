# Unified Search — Implementation Plan

Status: **Phases 1–3 implemented.** Phase 1 — query parser, address parser, FTS5 indexes + triggers + backfill, contacts index. Phase 2 — BM25 retriever, search service, search page wired to the global app-bar field. Phase 3 — `places` gazetteer + haversine `near:`, vector retriever (Mode A/B), RRF fusion, tier and recency multipliers. Phases 4+ still proposal.

Two Phase 3 details differ from what is written below, both deliberate and both explained where they are implemented:

- **Recency decay is floored at 0.75.** §5b's unclamped `1 / (1 + ln(1 + age_days/365))` reaches 0.26 at 17 years, and RRF scores sit in a band roughly 1.6% wide between adjacent ranks — so unfloored it stops being the "mild" decay §5b asks for and becomes the primary sort key, burying exactly the decades-old artifact a personal archive exists to hold. The floor keeps the spread at 1.33x, mild next to the tier spread of 1.9x, which *is* meant to dominate.
- **Fused searches page from memory, then hand back to lexical.** A reciprocal-rank score cannot be computed one page at a time, so a window of each retriever is fetched and ranked in one pass; once it is exhausted, lexical paging resumes from where the window ended and skips anything already shown. Totals count semantic-only hits separately from lexical ones, because the FTS cursor can never reach a row FTS does not match.
Scope: cross-collection search over photos/images, documents, emails, and (later) social posts.

---

## 0. What already exists (verified in this repo)

Before designing anything, here is the ground truth I found. Everything below is built on these facts.

| Capability | State | Where |
|---|---|---|
| Image embeddings (Qwen3-VL, 2048-d) | **Working** | `files_embeddings` rows with `type='file'`, written by `EmbeddingIsolate` |
| AI image descriptions + tags + landmarks | **Working** | `files.description`, `file_tags`, `file_landmarks`, written by `FileDescriptionIsolate` |
| Description-text embeddings | **Working** | `files_embeddings` rows with `type='description'` |
| Email embeddings | **Working, but whole-email** | `emails_embeddings`, one vector per message |
| Vector KNN | **Working, brute force** | `vector_full_scan()` — [database_repository.dart:121](client/lib/repositories/database_repository.dart:121) |
| Photo lat/long | **Present** | `files.latitude` / `files.longitude` |
| FTS5 / `bm25()` | **Available, unused** | Compiled into resqlite's bundled SQLite (`resqlite` README, "Built in \| FTS5") |
| Vector quantization (`vector_quantize_scan`) | **Available, unused** | Present in the bundled `vector_*.dylib` |
| A global search box | **Present but dead** | [adaptive_app_bar.dart:44](client/lib/widgets/adaptive_app_bar.dart:44) — a `TextField` with no handler |
| PDF / document text chunks | **Does not exist** | No table, no extractor, no isolate. `type='chunk'` is only anticipated in a comment |
| Any cross-module search | **Does not exist** | Photos has `searchQuery` → four `LIKE '%…%'` clauses; that's it |

Two things follow immediately:

1. **We are not starting from zero.** Vectors, descriptions, tags, landmarks, and geo are all already populated in the background. The retrieval layer is the missing piece, not the enrichment layer.
2. **Document search is a separate sub-project.** There is no text extraction anywhere in the app. Section 8 scopes it; it should not block shipping search over photos and email.

---

## 1. The one architectural decision that matters most

**Structured filters constrain the candidate set. They do not contribute to the ranking score.**

This is the difference between search that feels correct and search that feels like a slot machine. When someone types `from:bob@hotmail.com`, an email from Alice must be *impossible*, not merely *unlikely*. If `from:` were folded into a fused relevance score as one signal among many, a strong vector match from the wrong person would outrank a weak match from the right one — and the user would (correctly) conclude the filter is broken.

So the pipeline is two-phase, not one:

```
                   ┌──────────────────────────────────────────┐
  raw query  ───▶  │  PARSE  (deterministic, no LLM)          │
                   │  → hard filters + free-text remainder    │
                   └────────────────┬─────────────────────────┘
                                    │
              ┌─────────────────────┴──────────────────────┐
              │  hard filters become SQL WHERE clauses.    │
              │  They define the universe. Nothing         │
              │  outside it can ever surface.              │
              └─────────────────────┬──────────────────────┘
                                    │
        ┌───────────────────────────┼───────────────────────────┐
        ▼                           ▼                           ▼
   BM25 / FTS5              vector rerank               recency / signals
   (lexical rank)           (semantic rank)             (tier boost)
        │                           │                           │
        └───────────┬───────────────┘                           │
                    ▼                                           │
              RRF fusion                                        │
           (rank-based, scale-free)                             │
                    │                                           │
                    └────────────────────┬──────────────────────┘
                                         ▼
                                 final ranked list
```

**Filters pay twice, and the order of those payoffs matters.** The performance win is the obvious one — `from:` collapses hundreds of thousands of candidate vectors to a few hundred, turning a brute-force scan into an in-Dart cosine over a bounded set (§4, Mode A). The correctness win is the one to design around: hard filters are what make a result set *countable*, and therefore what make "all of" answerable at all (§2e).

Keep that order straight. Framed as an optimization only, a filter that looks "too strict" is tempting to soften into a score boost later — which silently reintroduces the wrong-sender failure this section exists to prevent.

---

## 2. Query parsing — and where the LLM does *not* belong

Project Rule 5 says: *use the model for judgment calls; if code can answer, code answers.* Applied honestly, most of "intent-aware query rewriting" turns out to be code.

### 2a. Deterministic parse (regex + lookup). No model call.

```
from:bob@hotmail.com      →  emails."from" = ?
to:mnimer@gmail.com       →  emails."to" LIKE ?
subject:invoice           →  FTS5 column filter  {subject}: invoice
has:attachment            →  emails.has_attachments = 1
is:unread                 →  emails.is_read = 0
type:image|pdf|email      →  content_type predicate / source selection
after:2026-01-01          →  date >= ?
before:2026-06            →  date < ?
in:"Work Gmail"           →  collection_id = ?
tag:beach                 →  file_tags
near:banff                →  file_landmarks OR lat/long radius
```

Grammar: `<field>:<value>`, value optionally quoted, `-` prefix negates, unmatched text is the free-text remainder. Roughly 150 lines and fully unit-testable with zero I/O. This is exactly the Gmail syntax people already have in their fingers.

**Bare years and month-names are also deterministic.** "party pictures from 2026" → `after:2026-01-01 before:2027-01-01`, remainder `party pictures`. A date grammar handles `2026`, `last summer`, `March`, `last week` far more reliably than a 2B-parameter local model will, and it costs microseconds instead of seconds.

### 2b. Name → address resolution is a **database lookup**, not a model call

"Summarize all of my interactions with russel jong" needs `russel jong` → the set of email addresses that person uses. That answer lives in the `emails` table, not in the model's head. The model does not know Russel's address; the database does.

> **The syntax is a shortcut, not the destination.** `from:mike@google.com` and the plain-English `emails from mike nimer` are the *same query* and must produce the *same plan* — a hard filter on the sender. The colon form skips resolution because the user already supplied the address; the prose form resolves through the contacts index first. Only the surface differs.
>
> This matters because the obvious alternative — letting un-prefixed prose fall through to vector search — is wrong on the merits. **Embeddings encode meaning, not identity.** Embedding `"from mike nimer"` and comparing it against email vectors retrieves messages *about* Mike, or that mention his name in the body, while systematically **missing** messages *from* Mike on unrelated topics. That missed set is precisely what was asked for. Proper nouns are the weakest thing a semantic vector carries.
>
> Detection is n-gram matching over `emails_contacts.display_name`, plus the prepositional patterns `from|to|with|between <person>` — deterministic, no inference. Resolves cleanly → hard filter + editable chip. Ambiguous → disambiguation chip. Resolves to nothing → §2d fallback.

```sql
SELECT DISTINCT "from" FROM emails WHERE "from" LIKE '%russel%jong%'
UNION
SELECT DISTINCT "from" FROM emails WHERE "from" LIKE '%rjong%'
```

Resolve to a candidate set, and when it's ambiguous **show the user a disambiguation chip** ("Russel Jong `<rjong@corp.com>` · 412 messages" / "`<russ.jong@gmail.com>` · 38 messages") rather than silently guessing. A visible, correctable chip beats an invisible, wrong LLM inference every time.

This requires a **contacts index** — a derived table of every address seen, with a display name and message count. It doesn't exist yet and is cheap to build (Section 6). It also unlocks autocomplete in the search box, which is worth more to daily use than any amount of query rewriting.

### 2c. What the LLM *is* actually for

One narrow job, and only when the deterministic parse leaves genuine ambiguity: **modality intent**. Should "graduation speech" search documents, photos, or email? A one-shot constrained-JSON call to the local model, using the same `response_format` + JSON-schema pattern already proven in `FileDescriptionIsolate`:

```json
{ "modalities": ["document","email"], "expanded_terms": ["commencement","valedictorian"] }
```

Hard constraints on this call:
- **Off the critical path.** Fire the deterministic search immediately and render results. If the model returns within ~800 ms, refine. Search must never block on inference.
- **Fails open.** No model, model busy, timeout, or malformed JSON → search all modalities. Never an error state.
- **Never invents filters.** It cannot emit `from:` or a date range. Those come from the parser or from the user. This keeps the model out of the correctness-critical path entirely.

> Worth stating plainly: `"Summarize all of my interactions with Russel Jong"` **is not a search query.** Search returns a ranked list; that sentence asks for a synthesized answer over the entire result set. The right move is to keep them separate — search retrieves and ranks, and a "Summarize these results" action hands the top-N to the existing `aichat` pipeline (Section 7). Building summarization into the search page would fuse two features that have different latency budgets, different failure modes, and different UIs.

### 2d. When the person doesn't resolve — and why the fallback leads with BM25

If `russel jong` matches no contact (never emailed, or referenced only inside message bodies), fall back to ranked retrieval over the free text. **BM25 leads, vector augments** — the reverse of the intuitive ordering.

A name is a lexical token. FTS5 matching `russel AND jong` against `plain_body` finds those messages exactly; a 2048-d embedding of the same phrase returns things that merely *feel* related. Vector fusion still earns its place — it catches "Russ", the reply thread that never restates the name — but it should add recall on top of a precise lexical spine, not replace it.

### 2e. "All" is a claim ranked retrieval cannot make

`all of my interactions` is a **completeness** requirement, and top-K similarity has no notion of completeness. This is the second reason the person-resolution path matters, independent of quality:

| | Hard-filtered path | Ranked-retrieval path |
|---|---|---|
| Denominator | Known — `412 messages` | Unknown |
| Coverage | Total, by construction | A sample, silently truncated |
| Summarization | Map-reduce over batches, genuinely "all" | Top-N only |
| Honest UI | "Summarizing 412 messages" | "Summarizing the 50 most relevant" |

Two consequences:

1. **Summarization over a filtered set must map-reduce**, not truncate. 412 messages will not fit a local model's context. Summarize in batches, then summarize the summaries — and reuse the existing chat pipeline rather than adding a second inference path.
2. **The UI must never imply completeness it doesn't have.** On the ranked path, say *"the 50 most relevant of ~2,000 matches"*. Silently summarizing a top-50 sample while the user reads it as "all" is the worst outcome available here — a confidently incomplete answer with no signal that anything was dropped.

---

## 3. BM25 keyword layer (FTS5)

FTS5 is already compiled in, and `bm25()` is its built-in ranking function — no hand-rolled scoring.

Use **external-content** tables so body text isn't duplicated on disk (an archive of 200k emails would otherwise roughly double):

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS emails_fts USING fts5(
  subject, "from", "to", cc, plain_body,
  content='emails', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2'
);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
  name, path, description,
  content='files', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2'
);
```

**Keep them in sync with SQL triggers, not application code.** Every write in this app already funnels through the main isolate's connection via the write relay, so triggers are guaranteed to fire — and unlike a Dart-side sync call, a trigger cannot be forgotten when someone adds a sixth scanner. Standard `AFTER INSERT / UPDATE / DELETE` triggers with the `'delete'` sentinel row pattern.

Two consequences to design around, both flagged in resqlite's own README:

- **Streams over virtual tables don't auto-invalidate.** Use `db.select`, not `db.stream`, for search. (Search is request/response anyway — this costs us nothing.)
- **Backfill is a one-time migration.** `INSERT INTO emails_fts(emails_fts) VALUES('rebuild')` inside the existing `PRAGMA user_version` migration path in `database_manager.dart`. On a large existing archive this takes real time — run it in the background with progress, not blocking app start.

Column-weighted BM25 so a subject-line hit beats a body hit:

```sql
SELECT rowid, bm25(emails_fts, 10.0, 3.0, 3.0, 1.0, 1.0) AS score
FROM emails_fts WHERE emails_fts MATCH ? ORDER BY score LIMIT 200
```

Note `bm25()` returns a **negative** score where more-negative is better; normalize sign at the boundary so downstream code never has to remember that.

---

## 4. Vector layer — and a correction to how it must be called

`vector_full_scan()` is brute force: it computes distance against **every row in the table**, then you join. That has a hard consequence people usually miss:

> **You cannot pre-filter a `vector_full_scan`.** Adding `WHERE emails."from" = ?` to the surrounding query filters the *results* of a scan that already touched everything. The cost is identical whether you wanted 3 candidates or 300,000.

At 2048 dims × 4 bytes = **8 KB per vector**. 100k photos = ~800 MB read per keystroke. Not viable for interactive search.

So the vector layer runs in one of two modes, chosen by whether filters are present:

**Mode A — filters present (the common case).** SQL/BM25 produces a bounded candidate set (≤ ~2000 ids). Fetch just those blobs and compute cosine similarity **in Dart**. 2000 × 2048 floats ≈ 16 MB and a few ms of SIMD-free dot products — genuinely fast, exactly-filtered, no extension call at all. This is the primary path.

**Mode B — no filters, pure semantic browse.** Fall back to `vector_full_scan` with a generous over-fetch, reusing the existing pattern in `findSimilarImages()`. Acceptable while corpora are small.

Escape hatch for Mode B at scale: the bundled extension ships `vector_quantize` / `vector_quantize_scan` / `vector_quantize_preload`. Wire it only when measurement says Mode B hurts — but design `VectorRetriever` behind an interface now so it can drop in without touching callers.

### Which vectors to search for images

For "find me landscape photos near Banff", there are two comparable 2048-d vectors per image:

- `type='file'` — the image itself. A **cross-modal** text→image comparison. Qwen3-VL supports it, but cross-modal similarity is reliably weaker than same-modal.
- `type='description'` — the AI caption's text. A **same-modal** text→text comparison, and generally the stronger signal for a natural-language query.

Search both and fuse. Deduplicate by `file_id` **before** fusion, keeping the better rank — otherwise a single photo occupies two slots and crowds out a genuinely different result. (`findSimilarFiles` already over-fetches `limit * 5` for exactly this reason; the same discipline applies here.)

---

## 5. Fusion, tiers, and ranking

### 5a. Reciprocal Rank Fusion

```
score(d) = Σ_over_retrievers  weight_r / (k + rank_r(d))      k = 60
```

RRF is the right choice specifically because BM25 scores and cosine distances are **not on comparable scales** and never will be. RRF only consumes ranks, so no normalization, no per-corpus tuning, no drift when the corpus grows. `k=60` is the standard default and is not worth tuning before there's real usage data.

Starting weights — flat, deliberately:

| Retriever | Weight |
|---|---|
| BM25 lexical | 1.0 |
| Vector (image) | 1.0 |
| Vector (description / body) | 1.0 |

Tune from observed behavior, not from intuition. Flat weights make it obvious which retriever is misbehaving.

### 5b. Source-tier boost (applied *after* fusion, as a multiplier)

Tiers encode "how much did the user actually invest in this artifact":

| Tier | Multiplier | Rationale |
|---|---|---|
| Favorited / in an album | 1.5 | Explicit human signal. The strongest one available. |
| Local filesystem, personal cloud drive | 1.2 | Curated, deliberately kept |
| Email body / sent mail | 1.0 | Baseline |
| Received email attachment | 0.8 | Someone else's artifact |
| Inline email asset (`is_inline=1`) | 0.0 → **excluded** | Logos, spacers, tracking pixels |

That last row is not a boost, it's a filter — and it's already precedented: `getFilesWithMissingEmbeddings` deliberately skips `is_inline=1` files because they pollute similarity search. Search must apply the same exclusion or every result page fills with newsletter logos.

Recency as a mild, **bounded** decay — `1 / (1 + ln(1 + age_days/365))`. Bounded matters: an unbounded decay makes a 2009 graduation speech unfindable, which is precisely the kind of thing a personal archive exists to hold.

---

## 6. Schema changes

All hand-written DDL in `database_manager.dart` per this project's conventions (no codegen, `PRAGMA user_version`-gated one-offs).

```sql
-- 1. FTS5 indexes + sync triggers  (Section 3)
CREATE VIRTUAL TABLE emails_fts USING fts5(... content='emails' ...);
CREATE VIRTUAL TABLE files_fts  USING fts5(... content='files'  ...);

-- 2. Email address index — powers name→address resolution (§2b) and the
--    field autocomplete (§13). `address` is stored ALREADY LOWERCASED and
--    is the identity key; `display_name` keeps human casing for display.
--    See §13a for why this cannot be a view over `emails`.
--
--    Named `emails_contacts`, not `contacts`, and keyed by ADDRESS, not by
--    person. It is a derived index over `emails` in the same family as
--    `emails_fts` and `emails_embeddings` — nothing in it is user-authored,
--    and it is fully rebuildable by re-parsing from/to/cc. One human with
--    three addresses is three rows here; this archive already holds
--    mnimer@allaire.com and mike@digitalchef.com both named "Mike Nimer".
--    A root-level contacts module would be person-level and consume this
--    table as one source, so the bare name `contacts` is reserved for it.
--    That is also why §2b resolves to a *set* of addresses and surfaces a
--    disambiguation chip rather than picking one.
CREATE TABLE IF NOT EXISTS emails_contacts (
  address        TEXT PRIMARY KEY,     -- normalized: lowercased, angle brackets stripped
  display_name   TEXT,                 -- most frequent variant seen, original casing
  local_part     TEXT NOT NULL,        -- substring before '@', for prefix ranking
  message_count  INTEGER NOT NULL DEFAULT 0,
  sent_count     INTEGER NOT NULL DEFAULT 0,   -- messages the user sent TO this address
  first_seen     INTEGER,
  last_seen      INTEGER
);
CREATE INDEX IF NOT EXISTS emails_contacts_name_idx  ON emails_contacts (display_name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS emails_contacts_local_idx ON emails_contacts (local_part  COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS emails_contacts_rank_idx  ON emails_contacts (message_count DESC);

-- 3. Document chunks — Section 8. Deliberately deferred; listed here so the
--    shape is agreed before anything is written against it.
CREATE TABLE IF NOT EXISTS file_chunks (
  id           TEXT PRIMARY KEY,
  file_id      TEXT NOT NULL,
  chunk_index  INTEGER NOT NULL,
  page         INTEGER,
  text         TEXT NOT NULL,
  FOREIGN KEY (file_id) REFERENCES files(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS file_chunks_file_idx ON file_chunks (file_id);

-- 4. Saved searches (Section 9, optional)
```

Chunk *vectors* need no new table: `files_embeddings` is already keyed `(file_id, type)` and its own comment anticipates `type='chunk'`.

**A schema problem to settle when chunking is actually built — deferred, not decided.** `files_embeddings`' primary key is `(file_id, type)`, one row per type per file. A 40-page PDF has *many* chunks, all `type='chunk'`, so without a change the second overwrites the first. Two ways out:

- **(a)** Key chunk vectors by `chunk_id` in a separate `file_chunks_embeddings` table.
- **(b)** Add a chunk-sequence column and widen the PK to `(file_id, type, sequence)`.

**Deferred to Phase 7; current preference is (b).** No chunk embeddings exist yet, so nothing is blocked either way.

One factual note for whenever it's picked up: (b) alters a table holding live rows — 4,711 today — so it needs a migration and touches the existing insert paths in `upsertFileEmbedding` and `saveFileDescription`; (a) leaves those untouched and lets chunk vectors be scanned independently of image vectors, which matters because scanning chunks during a photo query is wasted work. Not an argument to settle now, just the cost to weigh then.

*(Either way, this is the "silently overwrite" failure the existing `_migrateFilesEmbeddingsKey` comment at [database_manager.dart:660](client/lib/database_manager.dart:660) already warns about — worth not repeating.)*

---

## 7. Module structure and UI

### Global route, module-shaped code

```
client/lib/modules/search/
  models/
    search_query.dart          # parsed query: filters + free text + modalities
    search_result.dart         # unified result across all sources
    search_filters.dart
  services/
    query_parser.dart          # §2a — pure, no I/O, heavily unit-tested
    contact_resolver.dart      # §2b — name → addresses
    query_planner.dart         # §2c — optional LLM intent, fails open
    retrievers/
      bm25_retriever.dart
      vector_retriever.dart
      structured_retriever.dart
    rank_fusion.dart           # §5a — pure, unit-tested
    tier_boost.dart            # §5b — pure, unit-tested
    search_service.dart        # RxService<SearchCommand, SearchResults>
  pages/
    search_page.dart
  widgets/
    search_bar.dart, filter_chips.dart, result_tiles/, facet_sidebar.dart
```

**A module, routed globally.** It gets its own directory because it has pages + widgets + services and needs isolated tests, exactly like `photos` and `email`. It is *not* a fifth nav app — it's reached from chrome that's already on every screen.

Concretely: `/search?q=…` in `app_router.dart`, wired to the **existing dead `TextField`** in `AdaptiveAppBar`. That field is already in the global chrome on every page; giving it an `onSubmitted` is a two-line change and makes search feel native rather than bolted on. Add `⌘K` to focus it.

Note the deliberate non-goal: **per-module filter boxes stay as they are.** The photos toolbar's `LIKE '%…%'` filter is a different job — instant, local, narrowing the current view. Replacing it with the fusion pipeline would make it slower and worse. Two search affordances that do two different things is correct, not redundant.

### Result presentation

Default to **relevance-ranked and mixed-modality**, with type facets in a sidebar showing counts (`Photos 24 · Emails 112 · Documents 8`). Grouping by type by default would bury the best answer under a header; a "party pictures from 2026" query should lead with photos because they *ranked* first, not because a tab was selected.

Per-type tiles reusing existing widgets: photo thumbnails from the photos module, email rows from the email module. Each result shows **why it matched** — a highlighted BM25 snippet, or a "semantic match" indicator. When 30% of hits come from a vector, users need to see the reason or the results read as arbitrary.

Parsed filters render as **editable chips** above the results (`from: Russel Jong ×`). This makes the `<field>:<value>` syntax discoverable to people who'd never type it, and makes a mis-parse visibly correctable instead of mysteriously wrong.

### The summarize handoff

A "Summarize these results" button on the result set — not automatic. It takes the top-N results, formats them, and opens the `aichat` module with that context prefilled. That satisfies *"Summarize all of my interactions with Russel Jong"* without entangling search latency with generation latency, and reuses `LocalLlmContentGenerator` rather than adding a second inference path.

---

## 8. Document chunking (separate track, do not block search on it)

Nothing here exists today. Ordered by value-per-unit-effort:

1. **Email chunking — evaluated and adopted. See §16 for the measurement.**

   One vector currently represents an entire message, including a 40-message quoted thread ([email_embedding_isolate.dart:123](client/lib/modules/email/services/email_embedding_isolate.dart:123)). This was flagged as a *predicted* dilution risk, deliberately not acted on until measured: chunking means re-embedding every message, and that cost should be paid against evidence.

   **The evaluation ran on 2026-08-11 (§16). Chunking wins, and Phase 6 is no longer conditional.** Against the shipping single-vector approach, chunking improves overall MRR by +0.081 (95% CI [+0.047, +0.117]) on a 235-probe known-item benchmark, with the gain concentrated exactly where it was predicted — +0.119 on text buried late in a quoted chain. It is also the only variant tested that improves on the status quo at all; both truncation strategies score *worse* overall.

   The original stopping rule was "if neither signal shows up, single-vector is fine and Phase 6 drops entirely." Signal 1 showed up and is the whole result. Signal 2 (a general skew toward short emails) was not tested directly and did not need to be.

   One correction to the reasoning above, worth keeping because it inverted the cost argument: chunking was assumed to be *more* expensive. It is cheaper on this corpus. Nothing truncates before the model ([model_manager.py:305](aiserver/src/aichat/model_manager.py:305) passes no `max_length`), so attention runs quadratic over the full body — a 60k-character email costs 145s whole and 75s chunked. Projected across the corpus: **~22h single-vector vs ~13h chunked.**
2. **Text extraction** for PDF/DOCX/TXT. Belongs in `aiserver` (Python has real libraries; `pdfx` on the Flutter side renders pages, it doesn't extract text reliably). New endpoint `POST /util/extract-text` returning per-page text, mirroring the existing `/util/thumbnail` shape.
3. **A `DocumentChunkIsolate`** following the exact `EmbeddingIsolate` pattern — control port, write relay, pause-during-scan, `SequentialWriteQueue`. That shape is well-established here; don't invent a new one.
4. Chunking: ~512 tokens, ~64 overlap, prefer paragraph boundaries. Persist `page` so a result can deep-link into the PDF viewer.

---

## 9. Build order

Each phase ships something usable on its own.

| Phase | Deliverable | Unblocks |
|---|---|---|
| **1** | Query parser + FTS5 tables/triggers/backfill + contacts index + **natural-language person resolution (§2b)** | `from:`/`to:`/date filters work; `emails from mike nimer` resolves to the same filter; keyword search across email + filenames + descriptions |
| **2** | Search page, wired to the app-bar field. BM25 only. Filter chips, facets | End-to-end usable search. Ship it. |
| **3** | Vector retriever (Mode A candidate rerank) + RRF + tier boost | "landscape photos near Banff", "party pictures from 2026" |
| **4** | Query planner (LLM intent, off critical path, fails open) | Ambiguous queries route to the right modality |
| **5** | Summarize handoff to `aichat`, **map-reduce over filtered sets (§2e)** | "Summarize my interactions with Russel Jong" — genuinely over all 412, not a top-50 sample |
| **6** | Email chunking — **no longer conditional; measured and adopted, see §16** | Retrieval of text inside quoted threads; also cuts backfill time from ~22h to ~13h |
| **7** | Document extraction + chunk embeddings | "Find my graduation speech" over PDFs |

Phases 1–3 cover three of the four example queries. Phase 7 is the only one gated on new infrastructure.

---

## 10. Testing

Per Rule 9, tests should encode *why* behavior matters. The parser, fusion, and tier-boost are pure functions with no I/O — they carry most of the correctness and should carry most of the tests.

- **`query_parser_test.dart`** — `from:bob@x.com landscape photos` splits into filter + remainder; quoted values; negation; a bare `2026` becomes a year range; malformed input degrades to free text rather than throwing.
- **`contact_resolver_test.dart`** — the load-bearing one for §2b. `emails from mike nimer` and `from:mike@google.com` must produce an **identical** query plan; a name matching two contacts returns both rather than picking one; a name matching nothing returns empty and routes to §2d rather than silently dropping the words. If prose and syntax ever diverge here, natural-language queries quietly lose their filter and start returning other people's mail.
- **`rank_fusion_test.dart`** — a document ranked #1 by *one* retriever and absent from the others still places well (that's the entire point of RRF); identical inputs are order-stable.
- **`tier_boost_test.dart`** — a favorited photo outranks an equally-scored unfavorited one; **an `is_inline` asset never appears at all**, at any score. That second assertion is the regression test for a failure mode this codebase has already hit once, in embeddings.
- **`search_integration_test.dart`** — seeded DB, `from:` filter, asserting **zero** results from other senders. Not "fewer" — zero. This is the test that encodes Section 1's whole argument, and it must fail loudly if anyone ever folds a hard filter into the score.
- **BM25 sync** — insert/update/delete an email, assert `emails_fts` tracks it. Guards against a future scanner bypassing the triggers.

---

## 11. Decisions log

All open questions are resolved. No decision below blocks Phase 1.

| # | Question | Decision |
|---|---|---|
| 1 | Corpus size / vector scan limits | **Measured, not estimated.** ~6,000 vectors / 43 MB today — brute force is fine. Converted to a tripwire at 50k vectors per modality. See §12. |
| 2 | Left-nav entry for search? | **No.** The header search field triggers search and loads the UI. No `apps` row. |
| 3 | `near:` semantics | **Both sources**, gazetteer primary. Forward-geocode via a bundled GeoNames table + haversine in SQL; `file_landmarks` secondary. See §14. |
| 4 | Social posts | **Nothing now.** No scanner exists. Integrated into search when one is built; the retriever interface just needs to accept a fifth source type. |
| 5 | Gazetteer size | **`cities5000`** (~4 MB) over `cities1000` (~11 MB), to keep the bundle small. Contains Banff. Swappable later without a schema change. See §14d. |
| 6 | Chunk embedding schema | **Now due at Phase 6, not Phase 7.** The preferred shape was right: widen the PK with a chunk-sequence column. Email chunking needs it first. See §16d. |
| 7 | Tier-boost multipliers | **Accepted as starting values** (1.5 favorited / 1.2 local / 1.0 baseline / 0.8 attachment / excluded inline). Tune against real usage. See §5b. |
| 8 | Email chunking | **Resolved 2026-08-11: chunk.** Measured against three alternatives on a 235-probe benchmark; chunking is the only one that beats single-vector, and it is *cheaper* to build than the status quo. See §16. |
| 9 | Truncating the body before embedding | **Rejected, twice over.** First-N-characters and cut-at-the-quote-marker both improve retrieval of top-of-message text and both lose badly overall, because the deleted text becomes unfindable. Cutting at the *second* quote marker to keep the antecedent is statistically indistinguishable from a blind character cut at double the cost. See §16b. |

---

## 12. Corpus scale — measured, not estimated

Taken from the dev database (`com.xdtlabs.mydatastudio.dev`, 308 MB) on 2026-08-05:

| | Count | Embedding footprint |
|---|---|---|
| Files (active, non-inline) | 2,774 | — |
| `files_embeddings` (image + description) | 4,711 | 33.4 MB |
| `emails_embeddings` | 1,279 | 10.0 MB |
| **Total vectors** | **~6,000** | **43 MB** |
| Files with AI descriptions | 2,338 | — |
| `file_tags` / `file_landmarks` | 16,725 / 316 | — |
| Collections | 8 (5 file, 2 email, 1 drive) | — |

**Conclusion: brute-force `vector_full_scan` is fine today by a wide margin.** A full unfiltered scan reads 43 MB — single-digit milliseconds. Quantization now would be optimizing a non-problem.

That last row of context matters for a different reason: **16,725 tags and 2,338 descriptions already exist**, so the BM25 layer in Phase 1 has real material the day it ships. Keyword search over descriptions and tags is not waiting on any new enrichment.

### The tripwire

This archive is partially synced (Gmail 309 messages, Yahoo 1,058, spanning 2019–2026). A fully-synced account is typically 50k–250k messages; a real photo library 20k–100k images. That is 10–50× the current vector count.

**Threshold: ~50,000 vectors in a single modality.** Per-modality, not total — a photo query scans only photo vectors, so the ceiling applies to the largest single corpus, not their sum.

| Vectors (one modality) | Scan reads | Verdict |
|---|---|---|
| ~6,000 (today) | 43 MB | instant |
| 50,000 | 400 MB | acceptable, start watching |
| 100,000 | 800 MB | ~0.5–1 s — fix it |
| 500,000 | 4 GB | unusable |

**Decision: do not pre-optimize; instrument instead.** In Phase 3, log per-query vector count and latency. When a single modality crosses 50k, switch Mode B to `vector_quantize` + `vector_quantize_scan` — already compiled into the bundled `vector_*.dylib`, verified present. That is precisely why §4 requires `VectorRetriever` to sit behind an interface: the swap must be a one-class change, not a redesign.

Two things that blunt this risk regardless of corpus size:

- **Mode A is unaffected.** Any query carrying a filter — `from:`, a date range, a resolved contact, a modality — never runs a full scan. Section 2b's work to route natural-language person queries into hard filters is therefore also a performance feature: it keeps the common case permanently off the expensive path.
- **The expensive path is the narrow one.** Only a filterless, free-text, whole-corpus semantic browse triggers Mode B. That is the least common query shape, not the default.

---

## 13. Field autocomplete in the search box

When the caret sits inside a `from:` / `to:` / `cc:` token, open a filtering dropdown of real addresses so the user picks a valid one instead of typing a guess. Matching is case-insensitive; selection inserts the canonical stored form.

This is worth building for a reason beyond convenience: it **eliminates ambiguity at the source**. §2b resolves `mike nimer` → address *after* the fact and falls back to a disambiguation chip when the name is ambiguous. Autocomplete makes that path unnecessary for anyone using the syntax — they pick the exact address up front, so there is nothing to resolve and nothing to guess wrong.

It does **not** replace §2b. Prose queries (`emails from mike nimer`, typed without syntax) still need the resolver. The two paths converge on the same hard filter; autocomplete just makes the syntax path exact.

### 13a. The obvious implementation does not work

"Run a distinct query on email addresses" is the natural instinct, and the raw data defeats it. Sampled from the dev database:

```
from:  Google Payments <payments-noreply@google.com>
from:  "coderabbitai[bot]" <notifications@github.com>
to:    bmageau@hotmail.com,dave_meier@comcast.net,shelleyinfog@comcast.net
```

Three concrete problems:

1. **`from` is RFC 5322, not an address.** `SELECT DISTINCT "from"` yields *display-name + address* blobs. The same mailbox appears once per display-name variant, and `from:notifications@github.com` will never `=`-match the stored string.
2. **`to` and `cc` are comma-joined lists** — `Email.toDbMap()` does `to.join(',')`. `SELECT DISTINCT "to"` returns *recipient lists*, so the dropdown would offer `bmageau@hotmail.com,dave_meier@comcast.net,shelleyinfog@comcast.net` as one selectable row. In the dev DB that is 40 distinct "addresses" that are not addresses.
3. **Case variants already collide in real data.** 401 distinct raw `from` values collapse to 400 when lowercased — in only 1,367 messages. Your case-insensitivity instinct is confirmed by the data, not just by principle.

Also: a `DISTINCT` + dedup over `emails` is a full table scan **per keystroke**. Fine at 1,367 rows, unusable at 200,000.

So the dropdown must read the **materialized `emails_contacts` table** (§6), never `emails` directly. Populating it requires an address parser — split `to`/`cc` on commas, then parse each part as either `Display Name <addr@domain>` or a bare `addr@domain`, lowercase the address, keep the display name for presentation.

Note the formats are inconsistent by source: `from` carries display names, `to` in this data does not. The parser must handle both, and `display_name` is therefore nullable.

### 13b. Maintaining the index

RFC 5322 parsing is not expressible in a SQL trigger, so unlike the FTS5 tables (§3) this cannot be trigger-maintained. Populate it in Dart on the email write path, where every scanner already funnels through the main isolate's relay — a few addresses parsed per message is negligible against the embedding work happening alongside it.

- `message_count` increments per appearance; `sent_count` tracks appearances as a *recipient* of the user's own mail.
- `display_name` keeps the **most frequent** variant, not the first or last seen — automated senders vary their display name across messages while the address stays fixed.
- Provide a full-rebuild path as repair, and run it once as the Phase 1 backfill alongside the FTS5 rebuild.

### 13c. Generalize it — `from:` is not the highest-value field

The same mechanism serves every enumerable field, and building it generically costs barely more than hardcoding two:

| Field | Source | Rows today |
|---|---|---|
| `from:` `to:` `cc:` | `emails_contacts` | ~400 |
| **`tag:`** | `file_tags` | **16,725** |
| `near:` | `file_landmarks` | 316 |
| `in:` | `collections` | 8 |
| `type:` `has:` `is:` | static enum | — |

**`tag:` is the sleeper.** There are 16,725 AI-generated tags in the database and no one can remember or guess them — without autocomplete that filter is effectively undiscoverable. `from:` at least has the advantage that users know their own contacts.

So: a `FieldSuggestionProvider` interface with one implementation per field, dispatched on the field name the parser detects at the caret. New fields become new providers, not new UI.

### 13d. Ranking and interaction

**Rank by `message_count DESC`, not alphabetically.** Someone with 400 messages should outrank someone with 2. Within that, prefix matches beat substring matches — typing `mi` should put `Mike Nimer` above `adminmike@x.com`. Match against display name *and* address local part.

Display all three fields — `Mike Nimer · mike@xdtlabs.com · 412` — because message count is what lets a user tell two same-named contacts apart at a glance.

Desktop keyboard behavior, all of it required:

- Debounce ~120 ms as a **render throttle**, not as database protection — see §13e for why the DB isn't in the keystroke path at all.
- `↑`/`↓` navigate, `Tab` completes the highlighted entry, `Esc` dismisses.
- **`Enter` accepts the highlighted suggestion when the dropdown is open, and submits the search only when it is closed.** This is the classic autocomplete bug and it is worth calling out explicitly — getting it backwards means every completed selection also fires a premature search.
- Typing `from:` with an empty value opens the list immediately, showing top correspondents by volume. Useful before the user types anything.
- **Never force a selection.** Free text must stay valid — an address may be absent from `emails_contacts` because that mail was deleted, or the user is searching for something not yet synced. The dropdown suggests; it does not gate.

### 13e. Cache the lists; don't query per keystroke

**Decision: debounce yes, minimum-character threshold no — because the database is not in the keystroke path.**

A per-keystroke DB query with a 3-character minimum is the intuitive design, and it is protecting against a cost that measurement says isn't there. Distinct-value counts from the dev database:

| Field | Underlying rows | **Distinct values** | Cached size |
|---|---|---|---|
| `tag:` | 16,725 | **1,056** | ~16 KB |
| `from:` / `to:` / `cc:` | 1,367 emails | ~400 | ~25 KB |
| `near:` (landmarks) | 316 | 79 | ~2 KB |
| `in:` (collections) | 8 | 8 | — |

The dropdown offers *distinct* values, so `tag:` is a ~1,000-entry list, not a 16,725-entry one. **The entire suggestion corpus across every field is under 100 KB.** Load each field's list once, hold it in memory, filter in Dart.

That removes the round-trip a character minimum was meant to avoid, and it is strictly better than either alternative:

- **No minimum needed.** A 1- or 2-character prefix filters an in-memory list in microseconds. Blocking it would break the useful short cases — typing `mi` and seeing `Mike Nimer · 412` at the top is the ideal outcome, and a 3-char gate forbids it.
- **The empty-state list survives.** Opening `tag:` with nothing typed shows the most common tags (`nature`, `scenery`, `landscape`, `architecture`, `mountains`) — pure discoverability for a vocabulary no user could guess. A minimum would suppress exactly the case with the most value.
- **Debounce keeps a narrower job**: throttling widget rebuilds, not shielding SQLite.

Measured detail that reinforces this: `DISTINCT` defeats the prefix-range optimization anyway. All three variants — `LIKE 'be%'`, the same `COLLATE NOCASE`, and `LIKE '%be%'` — plan identically as `SCAN file_tags USING COVERING INDEX idx_file_tags_tag`. A character minimum wouldn't change the query plan, only how often that scan runs.

**Scaling.** Tag vocabulary saturates rather than growing linearly — 2,338 described photos yielded 1,056 distinct tags, with heavy reuse at the head (`nature` 1134, `scenery` 931). Expect low thousands at 100k photos, not tens of thousands. Contacts grow faster but stay small in absolute terms; 20,000 addresses is ~1.2 MB cached. Set a fallback threshold (say 50k distinct values) above which a provider switches to indexed DB queries — a `FieldSuggestionProvider` implementation detail, invisible to the UI.

**Invalidation.** Refresh a field's cache on scan completion and on the write paths that touch its source table. Staleness here is benign — a tag added seconds ago missing from autocomplete for a moment costs nothing, and free text still finds it.

**One data-quality wrinkle to expect:** near-duplicate tags coexist — `mountains` (552) and `mountain` (544) are separate values and will both appear. Not worth stemming for v1, but the dropdown should show counts so the user can tell which variant dominates.

### 13f. Build order impact

`emails_contacts` (table, parser, backfill) moves to **Phase 1** — §2b already depends on it, so autocomplete adds the UI and the suggestion providers, not the data layer. The dropdown itself lands in **Phase 2** with the search page.

Tests:

- **`address_parser_test.dart`** — `Display Name <a@b.com>`, `"quoted[bot]" <a@b.com>`, bare `a@b.com`, and a comma-joined multi-recipient string each parse to the right address set; casing normalizes; a malformed header yields no contact rather than throwing.
- **`contact_suggestion_test.dart`** — ranking puts high-`message_count` first; prefix beats substring; matching is case-insensitive; an address absent from `emails_contacts` still produces a usable free-text filter.

---

## 14. Geo search (`near:`) — what's available and what's actually there

### 14a. Two directions, and `near:` only needs one

The question conflates two operations that point opposite ways:

| | Direction | Needed for `near:`? |
|---|---|---|
| **Forward geocoding** | `"Banff"` → `(51.178, -115.571)` | **Yes** — once per query |
| **Reverse geocoding** | `(51.18, -115.57)` → `"Banff"` | No |

`near:banff` needs the *query term* turned into a center point, then a radius against coordinates already on `files`. That is **one forward lookup per query**. Photos are never geocoded at all.

**Do not reverse-geocode every photo and string-match the names.** Beyond the per-photo cost, it structurally breaks the feature: reverse geocoding yields *one* name per photo — the nearest populated place. A photo taken 12 km outside town resolves to some neighbouring hamlet, and `near:banff` silently misses it. Radius semantics cannot be recovered from a name comparison. The `reverse_geocoder` Python package works fine, it just answers the wrong question here.

(Reverse geocoding *does* have a separate use — labelling photos with place names so "Rome pictures" works as free text through BM25. That is an enrichment feature, not `near:`, and it can reuse the same gazetteer table rather than a Python round-trip.)

### 14b. Does SQLite support this? Verified against resqlite's actual build

| Capability | Available | Evidence |
|---|---|---|
| **Math functions** (`sin`, `cos`, `acos`, `radians`, `sqrt`) | **Yes** | `SQLITE_ENABLE_MATH_FUNCTIONS` in `resqlite/hook/build.dart:195` |
| **R-Tree** spatial index | **No** | Not in the enabled-features list; the amalgamation's R-Tree is `#ifdef`-guarded and never defined |
| Geopoly / SpatiaLite / `ST_*` | No | Not present |

So: **no spatial index, but full trigonometry in SQL.** Haversine runs directly in a query.

```sql
-- bounding box first (cheap, index-friendly), exact haversine second
SELECT f.*, 6371 * acos(min(1.0,
         cos(radians(:lat)) * cos(radians(f.latitude))
           * cos(radians(f.longitude) - radians(:lng))
         + sin(radians(:lat)) * sin(radians(f.latitude))
       )) AS km
FROM files f
WHERE f.latitude  BETWEEN :lat - :dLat AND :lat + :dLat
  AND f.longitude BETWEEN :lng - :dLng AND :lng + :dLng
HAVING km <= :radiusKm
ORDER BY km;
```

`:dLat = radiusKm / 111.32`; `:dLng = radiusKm / (111.32 * cos(radians(:lat)))`.

The `min(1.0, …)` guard is not decoration — floating-point error can push the `acos` argument fractionally above 1.0 for a point at zero distance, returning `NaN` and dropping the photo that matched *best*. Add an index on `(latitude, longitude)`.

### 14c. On the H3 idea — right tool, wrong problem

H3 works, and the k-ring-of-cells approach is sound. But it solves a problem this app does not have: **geo is not a performance bottleneck here.** A bounding-box scan over coordinate columns costs a few float comparisons per row — nothing like the 8 KB-per-row reads that make vector search expensive (§12). Even at 100k georeferenced photos this stays in the low milliseconds. Adding an H3 dependency, a cell column, and resolution/k-ring tuning buys nothing over `BETWEEN` plus `acos`.

Where H3 *would* genuinely earn its place: **map clustering**. If a map view with aggregated pins is ever built, hierarchical cell IDs give clustering at every zoom level via integer `GROUP BY`, which is exactly what H3 is good at and what haversine is bad at. Worth keeping in the back pocket for that — not for `near:`.

### 14d. The gazetteer: put it in the database

Bundle **GeoNames** (CC-BY 4.0) as a table in the app DB rather than calling out to Python or a network service:

```sql
CREATE TABLE IF NOT EXISTS places (
  id         INTEGER PRIMARY KEY,
  name       TEXT NOT NULL,
  ascii_name TEXT NOT NULL,
  latitude   REAL NOT NULL,
  longitude  REAL NOT NULL,
  country    TEXT,
  admin1     TEXT,          -- state / province
  population INTEGER
);
CREATE INDEX IF NOT EXISTS places_name_idx ON places (ascii_name COLLATE NOCASE);
```

Three benefits over a Python-side library: no IPC on the query path, works fully offline (matching the app's local-first premise), and it **doubles as the `near:` autocomplete source** from §13c for free.

**Pick the tier carefully — your own example depends on it.** GeoNames ships population-thresholded extracts, and Banff, Alberta has roughly 8,300 residents:

| Extract | Entries | Approx. size | Contains Banff? |
|---|---|---|---|
| `cities15000` | ~26k | ~2 MB | **No** |
| `cities5000` | ~55k | ~4 MB | Yes (barely) |
| `cities1000` | ~140k | ~11 MB | Yes |

**Decided: `cities5000`** (~4 MB) — chosen over `cities1000` to keep the app bundle small. It contains Banff and every town above 5,000 residents, which covers the realistic `near:` vocabulary; smaller villages and hamlets will not resolve and fall through to free text (§14f step 3). Swapping to `cities1000` later is a one-file asset change, not a schema change, if coverage proves too thin.

`cities15000` was rejected: it is the tempting default and does not contain Banff — it would fail the exact query in the spec.

Resolve ties by `population DESC` — there are dozens of Springfields, and the biggest is nearly always the intended one. Ambiguity surfaces as a disambiguation chip, same pattern as contacts (§2b).

### 14e. Reality check — measured coverage

Before building this, know what it can match. From the dev database:

| | Count |
|---|---|
| Active images | 2,376 |
| **With lat/long** | **242 (10.3%)** |
| Distinct vision-detected landmarks | 79 |

Coverage by source — every georeferenced image came from the local filesystem:

| Scanner | Images | With GPS |
|---|---|---|
| `file.local` | 2,352 | 242 (10.3%) |
| `file.gdrive` | 12 | 0 |
| `email.*` | 9 | 0 |

Two consequences worth accepting up front:

1. **`near:` can only ever match ~10% of the library**, and that fraction is a property of the source data (stripped EXIF on cloud/email images, screenshots, scans), not a bug to fix. A `near:` query returning few results is usually correct behaviour, and the UI should say *"242 photos have location data"* rather than implying an empty result means no matching photos.
2. **`file_landmarks` will not help with `near:banff`.** The 79 landmarks are famous *structures* the vision model recognized — Colosseum (85), Palace of Versailles (25), Neuschwanstein Castle (22), Leaning Tower of Pisa (6). Towns and regions do not appear. Landmarks are a genuinely useful filter, but they answer "photos of the Colosseum", not "photos near Banff". Both should feed `near:` as separate OR-ed sources, and the earlier §11 suggestion to ship landmarks-only *first* is wrong for the spec's own example query.

### 14f. Revised recommendation

`near:<place>` resolves in this order, all deterministic:

1. Exact/prefix match in `places` → forward geocode → haversine radius (default 25 km, tunable via `near:banff:50`).
2. Case-insensitive match against `file_landmarks` → OR into the same candidate set.
3. No match in either → treat as free text; BM25 will still find it in descriptions and filenames.

**Yes — build the `places` table. It is the primary path, and it is required for `near:` to work at all.**

Stating that unambiguously because §11 originally recommended deferring it and shipping landmarks first. That recommendation is **withdrawn**: the measured landmark data is famous structures (Colosseum, Versailles, Neuschwanstein), containing no towns or regions, so a landmarks-only `near:` cannot answer `near:banff` — the spec's own example. Landmarks are a useful *secondary* source, not a substitute.

Phase 3 ships both sources: `places` (step 1, primary) and `file_landmarks` (step 2, secondary). Gazetteer import is a one-time asset load alongside the FTS5 backfill.

---

## 15. As-built — the retrieval and ranking pipeline

Written after Phases 1–3 shipped. **Where this section and §§4–5 disagree, this
one is correct**: those describe intent, this describes what the code does and
why the constants hold the values they do. Every number below was measured
against the dev archive (2,338 photo-description vectors, 2,373 image vectors,
1,279 email vectors), not chosen by feel.

### 15a. The pipeline, end to end

```
raw query
  │
  ├─ QueryParser.parse ......... query_parser.dart
  │     filters (type:, tag:, from:, after:, near:, is:)
  │     modality words stripped from free text -> preferredTypes
  │     bare years, quoted phrases, near: radius
  │
  ├─ Bm25Retriever.search ...... retrievers/bm25_retriever.dart
  │     files_fts + emails_fts, FTS5 implicit AND
  │     ONE merged list, files and emails interleaved by score
  │     paged; own cursor per source
  │
  ├─ VectorRetriever.search .... retrievers/vector_retriever.dart
  │     QueryEmbedder -> POST /util/embedding (Qwen3-VL, 2048-d)
  │     Mode A (filters) | Mode B (no filters)
  │     per modality: dedupe by id -> sort -> floorAndCap
  │
  ├─ HybridRanker.fuse ......... hybrid_ranker.dart
  │     RankFusion.fuse over THREE lists: bm25, vector_file, vector_email
  │     then ResultRanking.adjust as multipliers, then re-sort
  │
  └─ SearchService ............. search_service.dart
        holds the whole fused list in _ranked; _sliceRanked pages within it
```

**The single most important structural fact:** `SearchService` pages *within*
the fused list. Anything a retriever drops is not "page two" — it is
unreachable, and nothing tells the user it existed. Every limit in the vector
path is therefore a ceiling on total recall, not a page size.

### 15b. Every tunable constant, and why it is what it is

| Constant | Value | File | Why |
|---|---|---|---|
| `RankFusion.k` | 60 | `rank_fusion.dart:14` | Standard RRF default. Ranks are stored **0-based** (`FusedRank.ranks` = "how many beat this one") and converted with `+ 1` at the one place it matters. Scoring off the stored value hands the top result `1/k` instead of `1/(k+1)` — the classic RRF bug. |
| `HybridRanker.retrieverWeights` | all 1.0 | `hybrid_ranker.dart:23` | Flat on purpose — weighting before real usage data just encodes a guess. |
| `SearchService.fusionWindow` | 500 | `search_service.dart:39` | Lexical rows entering fusion. |
| `VectorRetriever.candidateLimit` | 2000 | `vector_retriever.dart:82` | Memory **ceiling**, not the relevance gate. Was 300; see 15d. |
| `VectorRetriever.similarityFloorRatio` | 0.75 | `vector_retriever.dart:116` | Fraction of the *background-to-best* span a hit must clear. See 15e. |
| `VectorRetriever.minimumCandidatesForFloor` | 50 | `vector_retriever.dart:130` | Below this the median *is* one of the answers. See 15e. |
| `VectorRetriever.modeACandidateCap` | 4000 | `vector_retriever.dart:140` | ~32 MB of blobs — where reading them stops being free. |
| `ResultRanking.tierMultiplier` | 1.5 / 1.2 / 1.0 / 0.8 | `result_ranking.dart:30` | Unchanged from §5b. |
| recency decay | `1/(1+ln(1+age/365))`, floored **0.75** | `result_ranking.dart` | The floor is load-bearing: without it a 2009 photo cannot outrank recent marketing mail. |
| `ResultRanking.modalityPreferenceBoost` | **3.0** | `result_ranking.dart:93` | Was 1.4, which could not overcome double-listing. See 15f. |
| `EmbeddingModel.revision` | 2 | `services/embedding_model.dart:33` | Bump on anything that changes what a vector *means*. See 15g. |

### 15c. Filters constrain, never rank

The load-bearing invariant, shared by both retrievers through `SearchFilters`
(`search_filters.dart`). A row failing a filter must be **absent**, not merely
lower. `is_inline = 1` and `is_deleted = 1` are excluded everywhere, including
inside Mode B's post-scan `WHERE` — `vector_full_scan` cannot be pre-filtered,
so dropping that clause as "no filters means no clause" silently fills results
with newsletter logos.

Modality words are the deliberate exception, and the distinction is subtle:

- `type:image` (explicit) — a **filter**. Nothing else comes back.
- `"family photos"` — a **preference**. `QueryParser._extractModality` strips
  `photos` from the free text and records `preferredTypes = {image}`.
- `"photos"` alone, with nothing left after stripping — promoted to a real
  `type:` filter, because a bare modality word is a browse.

Stripping the word from the free text is not cosmetic. FTS5 ANDs its terms, and
an AI image description never contains the word "photos", so leaving it in
excluded exactly the photographs being searched for.

**This has a consequence worth remembering when reading measurements:** the app
never searches the string the user typed. `"Family Photos"` is searched as
`family`. Any benchmark run against the literal typed string is measuring a
query that never executes.

### 15d. Why `candidateLimit` is a ceiling, not a cap

At 300 it silently truncated real results. Measured: `snow mountains` clears the
floor on 481 photos and every one is on topic — 1,035 of 2,338 descriptions
mention mountains or snow — so a cap of 300 discarded 181 correct answers with
no indication they existed.

Raising it is close to free:

- **Mode A** has already read and scored up to `modeACandidateCap` blobs before
  the limit applies. A larger slice costs no extra I/O.
- **Mode B** passes `limit * 5` (files) or `limit * 2` (emails) to
  `vector_full_scan`, which computes a distance for **every** row regardless.
  The bound only limits how many `(rowid, distance)` pairs come back; no blobs
  travel with them.

The `* 5` over-fetch is not slack — a file carries both an image vector and a
description vector, and both compete for slots in the raw top-N before
deduplication collapses them.

### 15e. The similarity floor

`floorAndCap` (`vector_retriever.dart`), applied **per modality**, inside each
of `_rankInDart` (Mode A) and `_rankFromDistance` (Mode B):

```
baseline = median(retrieved similarities)
floor    = baseline + similarityFloorRatio * (best - baseline)
```

Three properties, each of which was a bug before it was a rule:

**1. Relative, not absolute.** Cosine's usable range moves with the query. 0.51
was right for `white dog` and returns nothing for a vaguer one.

**2. Recentred on the median, not on zero.** Cosine has no meaningful origin
here. A text query scores *every* email somewhat highly because both sides are
text — the median email scores **0.334** against an arbitrary query where the
median photo scores **0.205**. Anchored at zero, `0.75 * best` is genuinely
selective for photographs and barely above ordinary for mail:

| query | emails kept, zero-anchored | recentred |
|---|---|---|
| `white dog` | 31 (one about dogs; rest "Happy 4/20!", word-trivia) | **1** |
| `family` | 143 | **2** |
| `flight confirmation` | 310 | **6** (the actual eTickets) |

**3. Per modality, never global.** Text-vs-text reaches ~0.51 here while
text-vs-image tops out ~0.36. A single floor taken from the best email sits
above *every* photograph — the exact failure `HybridRanker`'s split vector
lists exist to prevent, reintroduced one layer down. `similarity_floor_test.dart`
asserts this directly.

**Guard:** below `minimumCandidatesForFloor` the floor is skipped entirely. The
median only estimates a background when most of the sample *is* background; at
three hits the median is the second one, and every search returned exactly one
result. It also keeps the floor away from the case it reasons badly about — a
selective filter, where the candidate set is already all relevant.

**Known limits, measured, not hypothetical:**

- *A modality cannot detect that it has nothing to say.* The floor derives from
  that modality's own best hit, so something always survives. This is not
  waiting on a cleverer statistic: `(top-median)/(p90-median)` for mail ranged
  **2.33 – 4.76** across six queries and was **highest** where mail was least
  relevant. The distribution does not reveal whether the top hit means
  anything. In practice the residual is 1–3 emails and at least loosely on
  topic.
- *It costs recall when the archive is dense in the topic.* `snow mountains`
  went 481 → 107 kept, because a median dragged upward by 1,035 mountain photos
  raises the floor against the very photos wanted. **If this becomes the
  complaint, move the baseline from the median to the 25th percentile** — a
  one-line change in `floorAndCap`.
- *The median is taken over what was retrieved, not the table.* Mode A sees the
  whole filtered set, so it is exact. Mode B sees the top N; while N covers the
  corpus (it does today — 2,000 against ~4,700 file and ~1,300 email vectors)
  it is also exact. Past that the sample skews high, biasing the floor
  **upward** and pruning harder. §12's 50k tripwire is where that starts.

### 15f. Fusion, and the double-listing trap

`RankFusion.fuse` **adds** contributions; nothing overrides anything:

```
score(d) = Σ_lists  weight / (k + rank_in_that_list)
```

The three lists are `bm25` (one merged list holding **both** files and emails),
`vector_file`, and `vector_email`. Mail and photos get separate vector lists
because cross-modal similarity is structurally lower — ranked in one list by raw
similarity, mail displaces photos regardless of relevance, and a search for
family pictures fills with marketing email.

A row present in two lists collects from both, and that is where the last bug
lived. Searching `family`:

- 107 emails contain the word; only **7 of 2,338 files** do.
- The top marketing email was in `bm25` **and** `vector_email` → `1/61 + 1/61 = 0.033`.
- A family photograph, found only by the vector pass because its description
  does not contain "family", tops out at `1/61 = 0.016`.

A 2× structural gap that a 1.4× preference could not close — the email was
winning on being double-counted, not on relevance. `modalityPreferenceBoost` is
now **3.0**, sized against that worst case: the 11th and last surviving photo,
personal-archive tier, old enough to take the full recency floor, scores
`1/71 * 3.0 * 1.2 * 0.75 = 0.038` and clears 0.033.

It remains a **preference, not a block sort** — an explicit product decision.
The multiplier scales the fused score, so it lifts the whole photo list without
flattening it, and a genuinely weak photograph stays weak: that same email still
beats a photo at vector rank 300 (0.0075). The same boost is applied in
`Bm25Retriever`'s lexical-only path so the ordering survives the AI subprocess
being down.

**Ordering note:** similarity does not survive to the final sort. It decides a
hit's rank *within its own retriever*; RRF converts rank to score and the value
is discarded. The final `ranked.sort` is on `RRF × tier × recency × modality`.
Past roughly rank 30 the multipliers, not relevance, decide local ordering — a
curated photo at rank 100 beats a received attachment at rank 240. Bounded, not
inverted.

### 15g. Embedding provenance

Every vector records the pipeline that produced it in `model_version`
(`EmbeddingModel.current`, e.g. `Qwen/Qwen3-VL-Embedding-2B@2`). The embedding
isolates treat anything else — including the `NULL` an existing row gets when
the column is added — as work to redo, so **adding the column is the
migration**. No manual DELETE, no way to forget.

This exists because of a silent catastrophe: `AutoModel.from_pretrained`
resolved to a class the checkpoint does not declare, discarding **625
language-model tensors** and randomly initialising them. Every vector was noise;
cosine over two incompatible spaces returns plausible numbers rather than an
error, so nothing downstream could detect it. Fixed in `7ac9c99`
(`AutoModelForImageTextToText` + a hard failure on missing keys). Verified after
rebuild: a stored description vector against a freshly computed one scores
**1.0000**, where it had been −0.02.

**Bump `EmbeddingModel.revision` for anything that changes what a vector
means** — a different checkpoint, different pooling, a new prompt template,
another loader fix. Description vectors are rebuilt before image vectors
deliberately: text costs ~0.28 s against ~3.8 s, and the description vector is
the stronger signal for a text query, beating the image vector on **44 of 45**
photos measured.

### 15h. Where to start when this misbehaves

| Symptom | Look here first |
|---|---|
| Irrelevant results of the *right* kind (swans for "white dog") | `similarityFloorRatio` — raise it, or move the baseline to p25 |
| Too few results; known matches missing | `minimumCandidatesForFloor`, then the floor's dense-topic recall loss (15e) |
| Results capped at a suspiciously round number | `candidateLimit`, and remember `_ranked` pages within itself |
| Mail intruding on a photo query | 15f — check whether the offender is double-listed before touching the floor |
| Photos not leading a "photos" query | `modalityPreferenceBoost`; confirm `QueryParser` actually set `preferredTypes` |
| A modality vanishing entirely | The floor must be per-modality. This is what `similarity_floor_test.dart` guards |
| Everything semantically wrong | `model_version` — check for `NULL` rows and unstamped vectors |
| `near:` silently doing nothing | The gazetteer asset. Import fails **open**; `pubspec.dev.yaml` is the source of truth, since the launch task regenerates `pubspec.yaml` from it |

**Measurement discipline:** benchmark the string the parser produces, not the
string the user typed (15c), and score each modality separately — a mixed list
sorted by raw similarity says more about which encoder produced a vector than
about relevance.

Tests: `client/test/modules/search/` — `similarity_floor_test.dart` (the floor,
including the per-modality trap), `vector_retriever_test.dart` (both modes),
`hybrid_search_test.dart` (fusion, tiers, pagination totals),
`rank_fusion_test.dart`, `result_ranking_test.dart`, `query_parser_test.dart`.

---

## 16. Email chunking — the Phase 6 decision, measured

Run 2026-08-11 against the dev database (20,431 emails, 1,556 embedded at the
time — the backfill from two fresh PST imports was still in flight). §8 required
this evaluation before Phase 6 could proceed; this section is that evaluation and
the decision it produced.

**Decision: chunk. ~2,000 characters, ~400 overlap, score an email by its best
chunk.** It is the only approach tested that beats what ships today, and it is
cheaper to build than what ships today.

### 16a. What the corpus actually looks like

Everything below follows from these numbers, so they come first.

| Embedded body length | chars | | Bodies over | count | share |
|---|---|---|---|---|---|
| p50 | 566 | | 2,000 | 3,175 | 15.6% |
| p75 | 1,225 | | 5,000 | 1,102 | 5.4% |
| p90 | 3,029 | | 10,000 | 624 | 3.1% |
| p95 | 5,416 | | 20,000 | 383 | 1.9% |
| p99 | 45,387 | | 40,000 | 286 | 1.4% |
| max | 243,841 | | 150,000 | 2 | — |

Two facts that decide most of the argument:

- **Half the corpus is under 566 characters.** For those, every strategy in this
  section produces a byte-identical vector. Whatever is chosen only touches the
  15.6% over 2,000 characters.
- **p95 → p99 jumps from 5,416 to 45,387.** That is not a tail, it is a second
  population of a few hundred enormous messages, and it dominates cost.

**The premise held.** Of long emails carrying a quoted chain (1,987 of them),
the median message is only **6.7% original text** — p50 of 220 characters of new
content. p75 is 15.9%. A long email really is mostly somebody else's older
message.

**A mechanism makes this worse than it looks.** The checkpoint pools with
`lasttoken` (`1_Pooling/config.json`, and [model_manager.py](aiserver/src/aichat/model_manager.py) matches it).
Under causal attention the final hidden state is most influenced by what sits
nearest the end — and for a reply chain the end is the *oldest* quoted message.
The single vector is not merely diluted by quoted text, it is weighted toward it.

### 16b. The four variants, and the result

Known-item retrieval over a 250-email pool (100 long, 150 short distractors;
bodies capped at 40,000 chars so the run would terminate — which flatters the
full-body variant). Ground truth is generated from the corpus: lift a verbatim
15-word span from a known email, query with it, record the rank of the source.
Spans come from two regions — **early** (original text, above the quote marker)
and **late** (past the halfway point, i.e. deep in the quoted chain). 235 probes,
paired bootstrap CIs.

| | early MRR | late MRR | **overall** | vs A (overall, 95% CI) | chars |
|---|---|---|---|---|---|
| **A** full body *(ships today)* | 0.593 | 0.537 | 0.561 | — | 1.00× |
| **B** chunked | 0.625 | **0.655** | **0.642** | **+0.081 [+0.047, +0.117]** | 1.22× |
| **C** first 1,000 chars | 0.654 | 0.375 | 0.496 | −0.065 [−0.105, −0.023] | 0.32× |
| **D** cut at quote marker | **0.671** | 0.316 | 0.470 | −0.091 [−0.135, −0.044] | 0.54× |
| **E** cut at *second* marker | 0.643 | 0.382 | 0.495 | −0.066 [−0.107, −0.026] | 0.69× |

Read in order:

1. **Truncation genuinely helps the text at the top.** D is the best variant on
   early probes, +0.078 over the status quo and significant. Removing the quoted
   tail measurably sharpens the vector for the new content — the `lasttoken`
   mechanism above, confirmed.
2. **And it loses anyway.** Deleting the quoted text makes it unfindable: D's
   late MRR falls to 0.316, median rank 11 against today's 2. Roughly 29% of the
   corpus carries a quoted chain, and for many threads the only copy of an
   earlier message is the quote inside a later reply. Both truncation strategies
   are net *worse* than doing nothing.
3. **E does not rescue the idea.** Keeping the message being replied to — so the
   reply sits next to its antecedent — is statistically indistinguishable from a
   blind character cut (0.495 vs 0.496 overall) at more than double the cost.
   The antecedent is a *different message about a different point*; adding it
   moves the vector toward that topic rather than sharpening this one. Being
   meaningful to a human reader and being matchable are different axes.
4. **Chunking is the only way to get (1) without (2).** The top of the message
   becomes its own undiluted chunk — the truncation benefit — while the quoted
   text stays indexed in chunks of its own. It is the only variant with a
   significant positive CI.

**Caveat, stated plainly:** verbatim-span probes are a best case for chunking on
the late axis, so +0.119 there likely overstates the gain for real paraphrase-style
queries. The deficit of C/D/E is *structural* — the text is not in the index at
all — and no query style changes that.

### 16c. Cost — the argument that inverted

§8 assumed chunking would be more expensive. On this corpus it is cheaper,
because nothing truncates before the model: [model_manager.py](aiserver/src/aichat/model_manager.py)
calls the processor with no `truncation` or `max_length`, and the model's window
is 262k tokens, so a 243k-character body goes through whole with quadratic
attention. Measured end-to-end against the running server:

| body | full body | chunked | |
|---|---|---|---|
| 5,003 chars | 1.9s | 3.7s (4 calls) | chunking 2× slower |
| 19,993 chars | 8.3s | 13.5s (13 calls) | chunking 1.6× slower |
| 59,814 chars | **145.0s** | **74.9s** (38 calls) | chunking 1.9× *faster* |

Below ~20k characters, per-call overhead dominates and chunking costs more.
Above it, quadratic attention dominates and chunking wins — decisively, and the
curve keeps steepening. Projected over all 20,277 bodies: **~22h single-vector
vs ~13h chunked.**

The real point is not the average, it is the shape: the current design has an
**unbounded worst case**, and 286 emails over 40k characters are paying it.
Chunking caps per-call cost by construction.

Storage: 38,815 vectors instead of 20,180 (1.92× rows, 318 MB vs 165 MB at
2048 f32). Only **3,175 emails (15.7%) produce more than one chunk** — the other
84% keep a single vector identical to today's. The migration is much smaller than
"chunk every email" implies.

### 16d. What implementing this requires

Not a config flip. In order:

1. **Schema.** `emails_embeddings` has `email_id` as PRIMARY KEY
   ([database_manager.dart](client/lib/database_manager.dart)). Widen it to
   `(email_id, chunk_index)`, matching decision #6's long-standing preference.
   Keep `model_version` per row — a partially re-chunked archive must be
   detectable (§15g).
2. **Producer.** `EmailEmbeddingIsolate.formatEmailForEmbedding` returns one
   string; it becomes a list. Headers (`from`/`to`/`cc`/`subject`) prefix
   **every** chunk — that is what the benchmark measured, and it is what keeps a
   chunk from the middle of a thread attributable to its message.
3. **Retriever.** `VectorRetriever` must score an email by its **best** chunk and
   emit it once. Without dedup a long thread occupies several result rows, and
   worse, RRF sees it as several documents — the double-listing trap in §15f,
   which is already known to distort ranking by 2×.
4. **The floor.** §15e measures the similarity floor from the per-modality
   *median*. Chunking changes that distribution: many more mail vectors, skewed
   toward fragments. Re-measure `similarityFloorRatio` for mail after the
   backfill; do not assume 0.75 still holds.
5. **Backfill.** Re-embedding is unavoidable. Do it before the current backfill
   finishes rather than after — at 7.6% complete when this was written, most of
   the work has not been spent yet, and chunked is the faster path to 100%.

### 16e. Reproducing this

Scripts are not checked in; they are throwaway harnesses against a live database
and a running aiserver. The method is what matters and is described fully above.
To re-run after a corpus change: build a stratified pool, generate probes by
lifting verbatim spans from known emails (ground truth for free), split them
early/late around the quote marker, embed each variant via `POST /util/embedding`,
and rank by cosine with a paired bootstrap over probes.

Two traps worth repeating:

- **Use enough probes.** A first pass at n=30 per cell put C ahead of B on early
  probes and could not separate anything else from noise. At n=235 the ordering
  held but every CI moved. Thirty probes cannot resolve a 0.06 MRR gap.
- **Pair the bootstrap.** All variants answer the same probes, so probe difficulty
  cancels only if the resampling is paired. Unpaired CIs here are roughly twice
  as wide and would have called the chunking result insignificant.
