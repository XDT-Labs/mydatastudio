# Search Module

The **Search module** provides unified, cross-source semantic and keyword search across files, emails, photos, and documents. It combines deterministic query parsing, BM25 full-text retrieval, vector similarity search, and result ranking into a single coherent interface.

## Overview

Search is organized into two phases:

1. **Query Parsing** — Deterministic (regex-based) extraction of hard filters (`from:`, `to:`, `tag:`, `near:`, etc.) and free-text remainder, with optional AI intent detection for modality selection
2. **Ranked Retrieval** — Multi-retriever fusion (BM25 lexical + vector semantic + geo proximity) with hard filters, recency boost, and hybrid ranking

**Key principle:** Structured filters are **hard constraints** that define the candidate set; they do not contribute to relevance scoring. A filter's failure mode must be "impossible result," not "low-ranked result."

## Architecture

### Directory Structure

```
modules/search/
  pages/
    search_page.dart                # Main search UI, global app-bar integration
  widgets/
    search_field.dart               # Search input with parser preview
    search_result_tile.dart          # Result item widget (file, email, etc.)
    search_facet_bar.dart            # Filter chips and suggestions
    search_email_sidebar.dart         # Email detail preview in search context
    search_file_sidebar.dart          # File detail preview in search context
    search_email_reader.dart          # Full email reader in search results
    summarize_results_dialog.dart     # "Summarize results" → aichat handoff
  services/
    search_service.dart              # Main search orchestrator
    query_parser.dart                # Deterministic filter/free-text parsing
    query_tokenizer.dart             # Tokenization for free-text processing
    query_planner.dart               # Optional AI intent detection for modality
    query_embedder.dart              # Embedding generation for semantic search
    result_ranking.dart              # RRF fusion + recency/tier scoring
    result_set_summarizer.dart       # Map-reduce over result set for summary
    retrievers/
      bm25_retriever.dart            # FTS5-backed lexical search
      vector_retriever.dart          # Brute-force cosine similarity over vectors
    search_filters.dart              # Hard filter application (WHERE clauses)
    search_detail_repository.dart    # Result detail queries (email body, file preview)
    hybrid_ranker.dart               # Reciprocal-rank-fusion (RRF) score combination
    rank_fusion.dart                 # Paged RRF window merging
    address_parser.dart              # Email address parsing and validation
    person_resolver.dart             # Name → email address resolution via contacts index
    place_repository.dart            # Gazetteer queries for location-based search
    geo.dart                         # Haversine distance, geo-proximity filtering
    email_contact_repository.dart    # Derived email contacts table queries
    near_resolver.dart               # `near:` filter → lat/long radius
    suggestions/
      field_suggestion_service.dart  # Field-level autocomplete
      field_suggestion.dart          # Individual suggestion model
  models/
    search_query.dart                # Parsed query representation (filters + free-text)
    search_result.dart               # Unified result item (file, email, or document)
    place.dart                       # Gazetteer place model (city, country, etc.)
```

### Main Search Flow

```
User input
    ↓
[QueryParser] — deterministic, no LLM
    → structured filters (from:, to:, tag:, near:, etc.)
    → free-text remainder
    ↓
[SearchFilters] — SQL WHERE clauses from hard filters
    Define the candidate set
    ↓
┌─────────────────┬──────────────────┬──────────────────┐
│                 │                  │                  │
↓                 ↓                  ↓                  │
[BM25]      [Vector Search]    [Geo Proximity]        │
Lexical rank  Semantic rank     Location rank         │
│                 │                  │                  │
└─────────────────┴──────────────────┴──────────────────┘
    ↓
[Hybrid Ranker] — Reciprocal-Rank Fusion
    Merge scores from all retrievers
    ↓
[Recency/Tier Boost] — Time decay + result-type boost
    ↓
[Result Ranking] — Final sorted list
    ↓
[SearchPage] — Display with pagination
```

## Query Parsing

### Deterministic Filters

The query parser recognizes the following structured filters. All are regex-based with zero inference:

| Filter | Example | Maps To |
|--------|---------|---------|
| `from:` | `from:bob@example.com` | `emails."from" = ?` |
| `to:` | `to:alice@example.com` | `emails."to" LIKE ?` |
| `subject:` | `subject:invoice` | FTS5 column filter `{subject}:invoice` |
| `has:` | `has:attachment` | `emails.has_attachments = 1` |
| `is:` | `is:unread` | `emails.is_read = 0` |
| `type:` | `type:image\|pdf\|email` | Content type / source selection |
| `after:`/`before:` | `after:2026-01-01` | Date range predicates |
| `in:` | `in:"Work Gmail"` | Collection ID filter |
| `tag:` | `tag:beach` | `file_tags` join |
| `near:` | `near:banff` | Gazetteer + haversine radius |

Bare years and month names are also parsed deterministically (e.g., "party photos from 2026" → `after:2026-01-01 before:2027-01-01`).

**See:** `query_parser.dart` (150 lines, fully testable).

### Person Resolution

Names in queries resolve to email addresses via the `emails_contacts` index (a derived table of every sender/recipient ever seen, with display name and message count). This is a **database lookup, not a model call**.

```dart
// "emails from mike nimer" is shorthand for the same query as "from:mike@example.com"
// Resolution happens via n-gram matching on display_name
// Ambiguous → show user a disambiguation chip
// No match → fall back to ranked retrieval (BM25 leads, vector augments)
```

**Why:** Embeddings encode meaning, not identity. Embedding "from mike nimer" retrieves messages *about* Mike or mentioning his name, while systematically **missing** messages *from* Mike on unrelated topics. Person resolution ensures a bare name is treated as a hard filter for identity.

### Optional AI Intent Detection

One narrow LLM job, **off the critical path**: modality intent (should "graduation speech" search documents, photos, or email?).

```dart
// Call QueryPlanner.askForModality(query) → returns {"modalities": ["document","email"]}
// Must fail open: no model, timeout, or error → search all modalities
// Never invents hard filters; only refines existing candidate set
```

**See:** `query_planner.dart`.

## Retrievers

### BM25 / FTS5 (Lexical)

Full-text search via SQLite FTS5. Indexes all email subject/body and file descriptions.

```dart
// Query: "graduation speech"
// FTS5 search: subject:(graduation AND speech) OR plain_body:(graduation AND speech)
// Ranks by BM25 relevance
```

**When to use:** Names, specific words, structured terms. Leading retriever when person resolution fails.

**See:** `retrievers/bm25_retriever.dart`.

### Vector Search (Semantic)

Brute-force cosine similarity over embeddings. Supports:
- **Image embeddings** (`files_embeddings` with `type='file'`) — Qwen3-VL 2048-d vectors
- **Description embeddings** (`files_embeddings` with `type='description'`) — Text embeddings from file/email descriptions
- **Email embeddings** (`emails_embeddings`) — Whole-email text vectors

```dart
// Query: "graduation speech"
// Generate embedding for query
// Cosine similarity against all file/email embeddings
// Top-K results by similarity
```

**Practical note:** Description vectors often outrank image vectors for text queries (44 of 45 measured queries), so the ranker must preserve that signal.

**See:** `retrievers/vector_retriever.dart`.

### Geo Proximity (Location)

Haversine distance from query location to photo lat/long.

```dart
// Query: "near:banff"
// Resolve "banff" to lat/long via gazetteer
// Find photos within ~radius km
```

**See:** `geo.dart`, `place_repository.dart`.

## Ranking & Fusion

### Reciprocal-Rank Fusion (RRF)

Combines BM25 rank, vector rank, and geo rank into a single score using harmonic mean (RRF formula: `Σ 1 / (k + rank)`).

**Why RRF:** Scale-free. A retriever that ranks one result at position 10 contributes the same relative signal as one ranking it at position 10,000. Avoids needing to normalize distances (which differ wildly between BM25 scores, cosine distances, and haversine km).

**Paging:** Fetches a window of each retriever, fuses them, renders one page. Exhausts the window → switches to lexical paging (BM25 is the default order when RRF is depleted).

**See:** `result_ranking.dart`, `rank_fusion.dart`.

### Recency Decay & Tier Boost

**Recency:** `1 / (1 + ln(1 + age_days/365))`, **floored at 0.75** to keep decade-old archives reachable. (Unfloored, the decay dominates RRF at ~7+ years of age.)

**Tier:** Result-type boost (e.g., email from a known contact ranks higher than email from a stranger). Metadata-based, not a hard filter.

**See:** `result_ranking.dart` (applies on top of RRF fusion).

## Result Set Summarization

Handed to aichat when user clicks "Summarize results."

The summarizer reads the entire filtered result set (respecting hard filters but ignoring rank/pagination), extracts text snippets from each result, and makes a **coverage claim** ("I read all 47 matching emails" or "All 12 photos matched").

This is important: the coverage claim is only honest if the hard-filter candidate set is countable, which is why person resolution (§2b of SEARCH_PLAN.md) being a hard filter — not a soft score signal — matters for this feature.

**See:** `result_set_summarizer.dart`.

## Database Integration

### Indexes & Triggers

- **FTS5 indexes** on `emails` (subject, plain_body) and `files` (description)
- **FTS5 triggers** keep indexes in sync on INSERT/UPDATE/DELETE
- **`emails_contacts`** — Derived table of all sender/recipient addresses, built on app startup from the emails table
- **`file_landmarks`** — Location tags extracted from file descriptions (e.g., "Banff National Park")

### File Chunks (Phase 7, not yet implemented)

PDF and document text extraction to support document-specific search. See `/SEARCH_PLAN.md` section 18 for design.

## Testing

Comprehensive test coverage for all major components:

```
client/test/modules/search/
  services/
    bm25_retriever_test.dart           # FTS5 indexing and ranking
    vector_retriever_test.dart          # Vector similarity search
    query_parser_test.dart              # Filter parsing and edge cases
    query_tokenizer_test.dart           # Tokenization variants
    query_planner_test.dart             # LLM intent detection
    rank_fusion_test.dart               # RRF merging logic
    result_ranking_test.dart            # Final score application
    hybrid_search_test.dart             # End-to-end fusion
    address_parser_test.dart            # Email address parsing
    person_resolver_test.dart           # Name → contact resolution
    near_search_test.dart               # Geo proximity queries
    field_suggestion_test.dart          # Autocomplete suggestions
    search_service_test.dart            # Main orchestrator
    result_set_summarizer_test.dart     # Coverage claim logic
  pages/
    search_page_test.dart               # Search page integration
  widgets/
    search_field_test.dart              # Input field behavior
    summarize_results_dialog_test.dart  # Summarization UI
  document_retrieval_test.dart          # Document search (Phase 7 spike)
  similarity_floor_test.dart            # Threshold validation (Phase 3)
```

Run via: `cd client && flutter test test/modules/search/`

## Key Design Decisions

1. **Hard filters define the universe.** Soft scoring never overrides a filter; if a filter is too strict, the user changes it, not the code.

2. **Person resolution is a hard filter.** A bare name like "mike" does not narrow the archive to one person without saying so.

3. **Modality intent is off the critical path.** Search launches immediately with deterministic parse; LLM refines in the background if it finishes within ~800 ms.

4. **BM25 leads when person fails.** Names are lexical tokens; FTS5 finds them exactly. Vector search adds semantic recall but should not replace exact lexical matching.

5. **RRF, not normalized averaging.** Scale-free fusion that works across vastly different score ranges (BM25, cosine, haversine).

6. **Recency decays, floored.** Personal archives exist to hold decades-old artifacts. Unfloored decay would bury them; the floor keeps old results reachable.

## See Also

- **SEARCH_PLAN.md** — Full design document with phase-by-phase breakdown, measured performance, floor thresholds, and Phase 7 (document search) design
- **AI Chat module** — Summarization and chat UI that consumes search results
- **Database** — FTS5 setup, schema triggers, and contacts index initialization in `database_manager.dart`

---

## Recent Changes

- **Phase 7 gating spike completed** (§18a-1, §18a-2, §18d-1): `docling-rs` builds on macOS, PDFs convert with full page provenance, ~71% of non-PDF documents parse
- **Floor measurements complete** (§16f): Mail floored at 0.70, files at 0.75. Sample bias was ~0.04; distribution change was zero.
- **Field suggestion autocomplete** (§13) implemented for contacts, tags, landmarks, collections, and fixed vocabularies
