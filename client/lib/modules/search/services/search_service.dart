import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/services/rx_service.dart';

/// Entry point for a search: parses the raw string, runs retrieval, publishes
/// results on [sink].
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

  @override
  Future<SearchResults> invoke(SearchCommand command) async {
    isLoading.add(true);
    try {
      final parsed = QueryParser.parse(command.rawQuery);
      lastQuery = parsed;

      // Nothing to constrain and nothing to rank is not an empty result, it is
      // the absence of a query — returning "no results found" for it reads as
      // a failure rather than a blank slate.
      if (!parsed.hasFilters && !parsed.hasFreeText) {
        sink.add(SearchResults.empty);
        return SearchResults.empty;
      }

      final results = await Bm25Retriever(
        command.database,
      ).search(parsed, limit: command.limit);

      sink.add(results);
      return results;
    } catch (e, stackTrace) {
      // A malformed query must not leave the page spinning forever. Parsing
      // is total by construction, so anything landing here is a storage-level
      // failure worth logging loudly and surfacing as empty.
      logger.e(
        'SearchService: search failed for "${command.rawQuery}": $e',
        error: e,
        stackTrace: stackTrace,
      );
      sink.add(SearchResults.empty);
      return SearchResults.empty;
    } finally {
      isLoading.add(false);
    }
  }
}

class SearchCommand implements RxCommand {
  final String rawQuery;
  final AppDatabase database;
  final int limit;

  /// Defaults to the retriever's own limit rather than restating a number
  /// here — two independently-maintained defaults is how one of them ends up
  /// quietly capping results the other thought it was returning.
  SearchCommand(
    this.rawQuery,
    this.database, {
    this.limit = Bm25Retriever.defaultLimit,
  });
}
