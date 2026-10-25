import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/hybrid_ranker.dart';
import 'package:mydatastudio/modules/search/services/near_resolver.dart';
import 'package:mydatastudio/modules/search/services/person_resolver.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';

/// The retrieval half of a search — parse, resolve, retrieve, fuse — with no
/// UI state.
///
/// [SearchService] pages and publishes on top of this for the search page.
/// Anything else that needs search results (the LLM's `search` tool) calls
/// this directly, because going through the singleton would reset whatever the
/// user has on the search page.
class ArchiveSearch {
  ArchiveSearch(this.database, this.embedder);

  final AppDatabase database;
  final QueryEmbedder embedder;

  /// Lexical rows fetched per source before fusion.
  ///
  /// Wider than a page because RRF ranks a list against a list: a document the
  /// vector pass ranked 12th can only be placed correctly if the lexical list
  /// is deep enough to say where *it* put that document.
  static const fusionWindow = 500;

  /// Runs the pipeline for [rawQuery].
  ///
  /// [limit] is the page size for a lexical-only search; a fused search always
  /// fetches [fusionWindow] so that ranking has both lists to work with.
  Future<ArchiveRetrieval> retrieve(
    String rawQuery, {
    int limit = Bm25Retriever.pageSize,
    SearchResultType? onlySource,
  }) async {
    final parsed = QueryParser.parse(rawQuery);

    // Nothing to constrain and nothing to rank is not an empty result, it is
    // the absence of a query — returning "no results found" for it reads as
    // a failure rather than a blank slate.
    if (!parsed.hasFilters && !parsed.hasFreeText) {
      return ArchiveRetrieval._blank(parsed);
    }

    // Two things parsing cannot finish on its own, both database lookups and
    // both resolved before anything is retrieved.
    //
    // People first: `emails from mike nimer` has to become the same hard
    // sender filter as `from:mike@x.com` (§2b). Left as free text it would go
    // to the vector pass, which encodes meaning rather than identity and so
    // returns mail *about* Mike while missing mail *from* him.
    //
    // Then `near:`, where a place name only becomes a constraint once the
    // gazetteer has turned it into a point, and a name nothing recognises
    // falls back to free text instead of constraining the query to zero rows.
    final withPeople = await PersonResolver(database).resolve(parsed);
    final resolved = await NearResolver(database).resolve(withPeople);

    final retriever = Bm25Retriever(database);
    final hits = await VectorRetriever(
      database,
      embedder,
    ).search(resolved, onlySource: onlySource);

    if (hits.isEmpty) {
      // No semantic signal — either the query is a pure browse or the AI
      // subprocess is unavailable. Either way lexical paging is both correct
      // and cheaper, so there is nothing to fuse and nothing to hold in
      // memory.
      return ArchiveRetrieval._(
        query: resolved,
        lexical: await retriever.search(
          resolved,
          limit: limit,
          onlySource: onlySource,
        ),
      );
    }

    final lexical = await retriever.search(
      resolved,
      limit: fusionWindow,
      onlySource: onlySource,
    );
    final ranked = await HybridRanker.fuse(
      lexical: lexical.results,
      vector: hits,
      loader: retriever,
      query: resolved,
    );
    final additions = await _semanticAdditions(
      retriever,
      resolved,
      lexical,
      ranked,
    );
    return ArchiveRetrieval._(
      query: resolved,
      lexical: lexical,
      ranked: ranked,
      semanticEmails: additions.emails,
      semanticFiles: additions.files,
    );
  }

  /// How many results the semantic pass added that no keyword would have found.
  ///
  /// Checked against the lexical index rather than assumed, because a hit both
  /// retrievers found is already inside the lexical total. Counting it twice
  /// would report a number the user cannot reach by scrolling — and a total
  /// that does not match the list is the failure people notice first.
  Future<({int emails, int files})> _semanticAdditions(
    Bm25Retriever retriever,
    ParsedQuery query,
    SearchResults lexical,
    List<SearchResult> ranked,
  ) async {
    final lexicalKeys = {for (final r in lexical.results) r.key};
    final newEmails = <String>[];
    final newFiles = <String>[];
    for (final result in ranked) {
      if (lexicalKeys.contains(result.key)) continue;
      if (result.isEmail) {
        newEmails.add(result.id);
      } else {
        newFiles.add(result.id);
      }
    }

    // Only rows past the lexical window can be ambiguous — inside it, absence
    // from `lexical.results` already proves the keywords missed them.
    final emailAmbiguous = lexical.emailTotal > lexical.emailOffset;
    final fileAmbiguous = lexical.fileTotal > lexical.fileOffset;

    final alsoLexicalEmails =
        emailAmbiguous
            ? await retriever.matchingIds(
              query,
              SearchResultType.email,
              newEmails,
            )
            : const <String>{};
    final alsoLexicalFiles =
        fileAmbiguous
            ? await retriever.matchingIds(
              query,
              SearchResultType.file,
              newFiles,
            )
            : const <String>{};

    return (
      emails: newEmails.where((id) => !alsoLexicalEmails.contains(id)).length,
      files: newFiles.where((id) => !alsoLexicalFiles.contains(id)).length,
    );
  }
}

/// What one run of [ArchiveSearch.retrieve] produced.
class ArchiveRetrieval {
  ArchiveRetrieval._({
    required this.query,
    required this.lexical,
    this.ranked,
    this.semanticEmails = 0,
    this.semanticFiles = 0,
  }) : isBlank = false;

  ArchiveRetrieval._blank(this.query)
    : lexical = SearchResults.empty,
      ranked = null,
      semanticEmails = 0,
      semanticFiles = 0,
      isBlank = true;

  /// The query after people and places were resolved (unresolved when blank).
  final ParsedQuery query;

  /// The lexical page (lexical-only search) or window (fused search).
  final SearchResults lexical;

  /// The fused ranking, or null when the search was lexical-only.
  final List<SearchResult>? ranked;

  /// Results only the semantic pass found, per source.
  final int semanticEmails;
  final int semanticFiles;

  /// True when the query had neither filters nor free text.
  final bool isBlank;

  /// The best [limit] results with archive-wide totals, for a caller that
  /// shows one list rather than paging.
  SearchResults top(int limit) {
    final ranked = this.ranked;
    if (ranked == null) {
      return SearchResults(
        results: lexical.results.take(limit).toList(),
        emailTotal: lexical.emailTotal,
        fileTotal: lexical.fileTotal,
        emailOffset: lexical.emailOffset,
        fileOffset: lexical.fileOffset,
        sourceFilter: lexical.sourceFilter,
      );
    }
    return SearchResults(
      results: ranked.take(limit).toList(),
      emailTotal: lexical.emailTotal + semanticEmails,
      fileTotal: lexical.fileTotal + semanticFiles,
      emailOffset: lexical.emailOffset,
      fileOffset: lexical.fileOffset,
      sourceFilter: lexical.sourceFilter,
      emailSemanticOnly: semanticEmails,
      fileSemanticOnly: semanticFiles,
    );
  }
}
