import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/place_repository.dart';

/// Turns `near:<place>` into something the retriever can constrain on.
///
/// Three outcomes per term, in priority order:
///
/// 1. The gazetteer knows the name — attach its coordinates, and the retriever
///    runs a radius against the photos that carry GPS.
/// 2. It does not, but a vision-detected landmark matches — leave the filter
///    alone, and the retriever's landmark join answers it.
/// 3. Neither — **drop the filter and hand the word back to free text.**
///
/// That third case is the one worth stating outright. A `near:` term nothing
/// can resolve is not an empty result, it is a word the user typed. Keeping it
/// as a filter would constrain the query to nothing and report zero matches;
/// demoting it lets BM25 find it in a filename or an AI description, which for
/// a village too small for the gazetteer is usually where the answer was.
class NearResolver {
  final AppDatabase db;
  final PlaceRepository places;

  NearResolver(this.db) : places = PlaceRepository(db);

  Future<ParsedQuery> resolve(ParsedQuery query) async {
    final nearFilters = query.filtersFor(FilterField.near);
    if (nearFilters.isEmpty) return query;

    final kept = <QueryFilter>[];
    final demoted = <String>[];

    for (final filter in query.filters) {
      if (filter.field != FilterField.near) {
        kept.add(filter);
        continue;
      }

      final place = await places.resolve(filter.value);
      if (place != null) {
        kept.add(
          filter.resolvedTo(
            latitude: place.latitude,
            longitude: place.longitude,
            placeLabel: place.label,
          ),
        );
        continue;
      }

      if (await _hasLandmark(filter.value)) {
        kept.add(filter);
        continue;
      }

      demoted.add(filter.value);
    }

    if (demoted.isEmpty) return query.copyWith(filters: kept);

    // Appended rather than prepended so the words the user actually wrote stay
    // in the order they wrote them; BM25 does not care, but the query echoed
    // back in the UI does.
    final freeText = [
      if (query.freeText.isNotEmpty) query.freeText,
      ...demoted,
    ].join(' ');
    return query.copyWith(filters: kept, freeText: freeText);
  }

  /// Whether any file carries [landmark] as a vision-detected landmark.
  ///
  /// Checked before demoting rather than left to the retriever, because the
  /// retriever cannot tell "this landmark matched nothing" from "this filter
  /// excluded everything" — both are an empty result set by the time it runs.
  Future<bool> _hasLandmark(String landmark) async {
    final rows = await db.select(
      'SELECT 1 FROM file_landmarks WHERE landmark LIKE ? COLLATE NOCASE '
      'LIMIT 1',
      [landmark],
    );
    return rows.isNotEmpty;
  }
}
