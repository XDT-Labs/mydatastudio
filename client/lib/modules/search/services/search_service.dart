import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/services/rx_service.dart';

/// Entry point for a search: parses the raw string, runs retrieval, publishes
/// results on [sink], and pages in more as the list scrolls.
///
/// Retrieval sits behind this so the page never talks to a retriever directly
/// — Phase 3 adds a vector pass and rank fusion here, and the UI should not
/// have to change when it does.
class SearchService extends RxService<SearchCommand, SearchResults> {
  static final SearchService _singleton = SearchService();
  static SearchService get instance => _singleton;

  final AppLogger logger = AppLogger(null);

  /// The parse of the query currently in [sink], so the UI can render filter
  /// chips that match the results it is showing rather than re-parsing and
  /// risking the two disagreeing.
  ParsedQuery? lastQuery;

  AppDatabase? _database;
  SearchResults _accumulated = SearchResults.empty;
  SearchResultType? _sourceFilter;
  bool _isLoadingMore = false;

  /// Whether another page remains to be fetched for the current query.
  bool get hasMore => _accumulated.hasMore;

  /// True while [loadMore] is in flight, so the list can show a footer spinner
  /// without confusing it for the initial load.
  bool get isLoadingMore => _isLoadingMore;

  /// Which single archive results are restricted to, or null for everything.
  SearchResultType? get sourceFilter => _sourceFilter;

  @override
  Future<SearchResults> invoke(SearchCommand command) async {
    isLoading.add(true);
    try {
      final parsed = QueryParser.parse(command.rawQuery);
      lastQuery = parsed;
      _database = command.database;
      _sourceFilter = command.sourceFilter;

      // Nothing to constrain and nothing to rank is not an empty result, it is
      // the absence of a query — returning "no results found" for it reads as
      // a failure rather than a blank slate.
      if (!parsed.hasFilters && !parsed.hasFreeText) {
        _accumulated = SearchResults.empty;
        sink.add(_accumulated);
        return _accumulated;
      }

      _accumulated = await Bm25Retriever(
        command.database,
      ).search(parsed, limit: command.limit, onlySource: command.sourceFilter);

      sink.add(_accumulated);
      return _accumulated;
    } catch (e, stackTrace) {
      // A malformed query must not leave the page spinning forever. Parsing
      // is total by construction, so anything landing here is a storage-level
      // failure worth logging loudly and surfacing as empty.
      logger.e(
        'SearchService: search failed for "${command.rawQuery}": $e',
        error: e,
        stackTrace: stackTrace,
      );
      _accumulated = SearchResults.empty;
      sink.add(_accumulated);
      return _accumulated;
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
      final next = await Bm25Retriever(database).search(
        query,
        emailOffset: _accumulated.emailOffset,
        fileOffset: _accumulated.fileOffset,
        onlySource: _sourceFilter,
      );

      // An empty page despite hasMore would otherwise let the scroll listener
      // ask forever. Treat it as the end.
      if (next.results.isEmpty) {
        _accumulated = SearchResults(
          results: _accumulated.results,
          emailTotal: _accumulated.emailTotal,
          fileTotal: _accumulated.fileTotal,
          emailOffset: _accumulated.emailTotal,
          fileOffset: _accumulated.fileTotal,
        );
      } else {
        _accumulated = _accumulated.append(next);
      }
      sink.add(_accumulated);
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
