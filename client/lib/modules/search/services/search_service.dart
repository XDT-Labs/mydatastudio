import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/hybrid_ranker.dart';
import 'package:mydatastudio/modules/search/services/near_resolver.dart';
import 'package:mydatastudio/modules/search/services/person_resolver.dart';
import 'package:mydatastudio/modules/search/services/query_embedder.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';
import 'package:mydatastudio/services/rx_service.dart';

/// Entry point for a search: parses the raw string, runs both retrievers,
/// fuses them, publishes results on [sink], and pages in more as the list
/// scrolls.
///
/// Two pagination strategies live here, and which one applies depends on
/// whether the semantic pass contributed anything.
///
/// - **Lexical only** — every page is a SQL `OFFSET` against the FTS index.
///   Cheap, and every match is reachable.
/// - **Fused** — a reciprocal-rank score is meaningless without both
///   retrievers' full lists, so a window of each is fetched and ranked in one
///   go, then paged from memory. Once that window is exhausted the lexical
///   tail resumes from where the window ended, skipping anything already
///   shown. Fusion applies to the head, where ranking actually matters, and the
///   long tail stays in lexical order rather than being fetched to rank it.
class SearchService extends RxService<SearchCommand, SearchResults> {
  static final SearchService _singleton = SearchService();
  static SearchService get instance => _singleton;

  final AppLogger logger = AppLogger(null);

  /// Lexical rows fetched per source before fusion.
  ///
  /// Wider than a page because RRF ranks a list against a list: a document the
  /// vector pass ranked 12th can only be placed correctly if the lexical list
  /// is deep enough to say where *it* put that document.
  static const fusionWindow = 500;

  /// Overridable so tests can supply a deterministic embedder — and so a build
  /// with no AI subprocess can turn the semantic pass off entirely.
  QueryEmbedder embedder = AiServerQueryEmbedder.instance;

  /// The parse of the query currently in [sink], so the UI can render filter
  /// chips that match the results it is showing rather than re-parsing and
  /// risking the two disagreeing. Holds the *resolved* query, so paging reuses
  /// the gazetteer lookup rather than repeating it.
  ParsedQuery? lastQuery;

  AppDatabase? _database;
  SearchResults _accumulated = SearchResults.empty;
  SearchResultType? _sourceFilter;
  bool _isLoadingMore = false;

  /// The fused ranking, or null when this search is lexical-only.
  List<SearchResult>? _ranked;
  int _shown = 0;

  /// Keys already published, so the lexical tail cannot re-show a row that the
  /// fused head already placed.
  final Set<String> _emitted = {};

  bool get hasMore => _accumulated.hasMore;
  bool get isLoadingMore => _isLoadingMore;
  SearchResultType? get sourceFilter => _sourceFilter;

  @override
  Future<SearchResults> invoke(SearchCommand command) async {
    isLoading.add(true);
    try {
      final parsed = QueryParser.parse(command.rawQuery);
      _database = command.database;
      _sourceFilter = command.sourceFilter;
      _ranked = null;
      _shown = 0;
      _emitted.clear();

      // Nothing to constrain and nothing to rank is not an empty result, it is
      // the absence of a query — returning "no results found" for it reads as
      // a failure rather than a blank slate.
      if (!parsed.hasFilters && !parsed.hasFreeText) {
        lastQuery = parsed;
        return _publish(SearchResults.empty);
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
      final withPeople = await PersonResolver(command.database).resolve(parsed);
      final resolved = await NearResolver(command.database).resolve(withPeople);
      lastQuery = resolved;

      final retriever = Bm25Retriever(command.database);
      final hits = await VectorRetriever(
        command.database,
        embedder,
      ).search(resolved, onlySource: command.sourceFilter);

      if (hits.isEmpty) {
        // No semantic signal — either the query is a pure browse or the AI
        // subprocess is unavailable. Either way lexical paging is both correct
        // and cheaper, so there is nothing to fuse and nothing to hold in
        // memory.
        return _publish(
          await retriever.search(
            resolved,
            limit: command.limit,
            onlySource: command.sourceFilter,
          ),
        );
      }

      final lexical = await retriever.search(
        resolved,
        limit: fusionWindow,
        onlySource: command.sourceFilter,
      );
      final ranked = await HybridRanker.fuse(
        lexical: lexical.results,
        vector: hits,
        loader: retriever,
        query: resolved,
      );
      _ranked = ranked;

      final additions = await _semanticAdditions(
        retriever,
        resolved,
        lexical,
        ranked,
      );

      return _publish(
        _sliceRanked(
          lexical: lexical,
          limit: command.limit,
          extraEmails: additions.emails,
          extraFiles: additions.files,
        ),
      );
    } catch (e, stackTrace) {
      // A malformed query must not leave the page spinning forever. Parsing
      // is total by construction, so anything landing here is a storage-level
      // failure worth logging loudly and surfacing as empty.
      logger.e(
        'SearchService: search failed for "${command.rawQuery}": $e',
        error: e,
        stackTrace: stackTrace,
      );
      _ranked = null;
      return _publish(SearchResults.empty);
    } finally {
      isLoading.add(false);
    }
  }

  /// Fetches the next page and appends it to what is already published.
  ///
  /// Guarded against re-entry: a scroll listener fires on every frame near the
  /// bottom, so without this one flick would queue a dozen identical pages and
  /// append each of them.
  Future<void> loadMore() async {
    final query = lastQuery;
    final database = _database;
    if (query == null || database == null) return;
    if (_isLoadingMore || !_accumulated.hasMore) return;

    _isLoadingMore = true;
    try {
      // The fused head is served from memory before any further SQL: it was
      // ranked as a whole, and handing out a lexical page mid-way through it
      // would interleave two different orderings.
      final ranked = _ranked;
      if (ranked != null && _shown < ranked.length) {
        _publish(
          _accumulated.append(_sliceRanked(limit: Bm25Retriever.pageSize)),
        );
        return;
      }

      final next = await Bm25Retriever(database).search(
        query,
        emailOffset: _accumulated.emailOffset,
        fileOffset: _accumulated.fileOffset,
        onlySource: _sourceFilter,
      );

      // Anything the fused head already placed must not appear a second time
      // further down the list.
      final fresh =
          next.results.where((r) => !_emitted.contains(r.key)).toList();

      // An empty page despite hasMore would otherwise let the scroll listener
      // ask forever. Treat it as the end.
      if (next.results.isEmpty) {
        _publish(
          SearchResults(
            results: _accumulated.results,
            emailTotal: _accumulated.emailTotal,
            fileTotal: _accumulated.fileTotal,
            emailOffset: _accumulated.emailTotal,
            fileOffset: _accumulated.fileTotal,
            sourceFilter: _sourceFilter,
          ),
        );
        return;
      }

      _publish(
        _accumulated.append(
          SearchResults(
            results: fresh,
            // Totals stay as first computed: they already account for the
            // semantic additions, which a later lexical page knows nothing
            // about and would otherwise silently drop.
            emailTotal: _accumulated.emailTotal,
            fileTotal: _accumulated.fileTotal,
            emailOffset: next.emailOffset,
            fileOffset: next.fileOffset,
            sourceFilter: _sourceFilter,
            emailSemanticOnly: _accumulated.emailSemanticOnly,
            fileSemanticOnly: _accumulated.fileSemanticOnly,
          ),
        ),
      );
    } catch (e, stackTrace) {
      logger.e(
        'SearchService: loadMore failed: $e',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Re-runs the current query restricted to [source] (null for everything).
  ///
  /// A re-query rather than a filter over loaded rows: the facet counts are
  /// archive totals, so selecting "Photos & Files 1,134" has to be able to
  /// reach all 1,134 — not just those that fit in the pages already fetched
  /// alongside the mail.
  Future<void> setSourceFilter(SearchResultType? source) async {
    final query = lastQuery;
    final database = _database;
    if (query == null || database == null) return;
    if (_sourceFilter == source) return;

    await invoke(SearchCommand(query.raw, database, sourceFilter: source));
  }

  /// Takes the next [limit] fused results, advancing the display cursor.
  ///
  /// The lexical cursors are carried straight through from [lexical]: they mark
  /// how far into the FTS index the window reached, which is exactly where the
  /// tail must resume once the fused head runs out.
  SearchResults _sliceRanked({
    SearchResults? lexical,
    required int limit,
    int extraEmails = 0,
    int extraFiles = 0,
  }) {
    final ranked = _ranked ?? const <SearchResult>[];
    final slice = ranked.skip(_shown).take(limit).toList();
    _shown += slice.length;
    for (final result in slice) {
      _emitted.add(result.key);
    }

    return SearchResults(
      results: slice,
      emailTotal:
          (lexical?.emailTotal ?? _accumulated.emailTotal) + extraEmails,
      fileTotal: (lexical?.fileTotal ?? _accumulated.fileTotal) + extraFiles,
      emailOffset: lexical?.emailOffset ?? _accumulated.emailOffset,
      fileOffset: lexical?.fileOffset ?? _accumulated.fileOffset,
      sourceFilter: _sourceFilter,
      rankedRemaining: ranked.length - _shown,
      emailSemanticOnly:
          lexical == null ? _accumulated.emailSemanticOnly : extraEmails,
      fileSemanticOnly:
          lexical == null ? _accumulated.fileSemanticOnly : extraFiles,
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

  SearchResults _publish(SearchResults results) {
    _accumulated = results;
    sink.add(results);
    return results;
  }
}

class SearchCommand implements RxCommand {
  final String rawQuery;
  final AppDatabase database;
  final int limit;

  /// Restricts retrieval to one archive. Set by a facet selection.
  final SearchResultType? sourceFilter;

  /// Defaults to the retriever's own page size rather than restating a number
  /// here — two independently-maintained defaults is how one of them ends up
  /// quietly capping results the other thought it was returning.
  SearchCommand(
    this.rawQuery,
    this.database, {
    this.limit = Bm25Retriever.pageSize,
    this.sourceFilter,
  });
}
