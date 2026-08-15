import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/geo.dart';

/// A built `WHERE` clause and its bound parameters.
class SourceFilter {
  final String sql;
  final List<Object?> params;
  const SourceFilter(this.sql, this.params);
}

/// Turns a [ParsedQuery]'s filters into SQL predicates.
///
/// Shared by every retriever rather than owned by one, and that is the point.
/// `from:bob` has to make mail from anyone else *impossible* — not merely
/// unlikely — in the lexical pass and the vector pass alike. Two retrievers
/// maintaining their own copies of these clauses would drift, and the symptom
/// would be a semantically strong match from the wrong person outranking a
/// weak one from the right person: the exact failure the design forbids.
///
/// Repeats of one field OR together; distinct fields AND.
class SearchFilters {
  /// Radius for a `near:` term that does not name one (`near:banff:50` does).
  ///
  /// 25 km is roughly "this trip" rather than "this town": EXIF coordinates are
  /// where the shutter fired, not where the user thinks they were, and a
  /// tighter radius drops the hike, the drive out, and the restaurant one
  /// valley over — all of which belong to the same set of photos.
  static const defaultRadiusKm = 25;

  /// Whether [type] can satisfy [query] at all.
  ///
  /// `type:` selects a *source*, not a row predicate — `type:email` must not
  /// merely rank files lower, it must exclude them. A negated `-type:email`
  /// inverts that.
  static bool sourceWanted(ParsedQuery query, SearchResultType type) {
    final typeFilters = query.filtersFor(FilterField.type);
    if (typeFilters.isEmpty) return true;

    const emailAliases = {'email', 'mail', 'message'};
    bool namesType(QueryFilter f) {
      final v = f.value.toLowerCase();
      return type == SearchResultType.email
          ? emailAliases.contains(v)
          : !emailAliases.contains(v);
    }

    final positive = typeFilters.where((f) => !f.negated).toList();
    final negative = typeFilters.where((f) => f.negated).toList();

    if (negative.any(namesType)) return false;
    if (positive.isEmpty) return true;
    return positive.any(namesType);
  }

  /// The email `WHERE` clause, or null when no mail can satisfy [query].
  static SourceFilter? forEmails(ParsedQuery query) {
    if (!sourceWanted(query, SearchResultType.email)) return null;

    // A `tag:`/`near:` query is about files; mail cannot satisfy it, and
    // returning mail anyway would look like the filter was ignored.
    if (query.filtersFor(FilterField.tag).any((f) => !f.negated) ||
        query.filtersFor(FilterField.near).any((f) => !f.negated)) {
      return null;
    }

    final where = <String>['e.is_deleted = 0'];
    final params = <Object?>[];

    _addLike(query, FilterField.from, 'e."from"', where, params);
    _addLike(query, FilterField.to, 'e."to"', where, params);
    _addLike(query, FilterField.cc, 'e.cc', where, params);
    _addParticipant(query, where, params);
    _addLike(query, FilterField.subject, 'e.subject', where, params);
    _addDateRange(query, 'e.date', where, params);
    _addCollection(query, 'e.collection_id', where, params);

    for (final f in query.filtersFor(FilterField.has)) {
      if (f.value.toLowerCase().startsWith('attach')) {
        where.add('e.has_attachments = ${f.negated ? 0 : 1}');
      }
    }
    for (final f in query.filtersFor(FilterField.is_)) {
      final v = f.value.toLowerCase();
      if (v == 'unread') where.add('e.is_read = ${f.negated ? 1 : 0}');
      if (v == 'read') where.add('e.is_read = ${f.negated ? 0 : 1}');
    }

    return SourceFilter(where.join(' AND '), params);
  }

  /// The file `WHERE` clause, or null when no file can satisfy [query].
  static SourceFilter? forFiles(ParsedQuery query) {
    if (!sourceWanted(query, SearchResultType.file)) return null;

    // Mail-only fields cannot be satisfied by a file.
    if (query.filtersFor(FilterField.from).any((f) => !f.negated) ||
        query.filtersFor(FilterField.to).any((f) => !f.negated) ||
        query.filtersFor(FilterField.cc).any((f) => !f.negated) ||
        query.filtersFor(FilterField.participant).any((f) => !f.negated) ||
        query.filtersFor(FilterField.has).any((f) => !f.negated) ||
        query.filtersFor(FilterField.is_).any((f) => !f.negated)) {
      return null;
    }

    // is_inline excludes message-body assets — spacers, logos, tracking
    // pixels. The embedding pipeline already skips them for the same reason;
    // without this every result page fills with newsletter furniture.
    final where = <String>['f.is_deleted = 0', 'f.is_inline = 0'];
    final params = <Object?>[];

    _addDateRange(query, 'f.date_created', where, params);
    _addCollection(query, 'f.collection_id', where, params);
    _addJoinTable(
      query,
      FilterField.tag,
      'SELECT file_id FROM file_tags WHERE tag LIKE ? COLLATE NOCASE',
      where,
      params,
    );
    _addNear(query, where, params);

    for (final f in query.filtersFor(FilterField.type)) {
      final predicate = _contentTypePredicate(f.value.toLowerCase());
      if (predicate == null) continue;
      where.add(f.negated ? 'NOT ($predicate)' : predicate);
    }

    return SourceFilter(where.join(' AND '), params);
  }

  /// `participant:` — anyone on the message, in any role.
  ///
  /// Each term matches across sender, recipients and copies, because that is
  /// what "with" and "between" mean: correspondence is bidirectional, and a
  /// thread alternates direction with every reply. Expressed as `from:` or
  /// `to:` it would return half of each conversation.
  ///
  /// Combination is the part that differs from every other field, and it has to:
  /// **OR within one person, AND across people.** One person owning three
  /// addresses means "any of these three" — AND'ing them matches nothing, since
  /// a message carries one sender. Two *different* people means "both were
  /// there" — OR'ing them would answer "emails between mike and sarah" with
  /// every message either of them ever touched, which is not a conversation
  /// between them and is a far larger set than the question implies.
  ///
  /// The grouping key is [QueryFilter.sourceText], the phrase each filter was
  /// resolved from: every address for one name shares one phrase, and a second
  /// person arrives with a different one. Filters the user typed carry no
  /// source text, so they land in a single group and OR — which is the
  /// documented behaviour for repeats of any typed field.
  static void _addParticipant(
    ParsedQuery query,
    List<String> where,
    List<Object?> params,
  ) {
    final all = query.filtersFor(FilterField.participant);
    if (all.isEmpty) return;

    const columns = ['e."from"', 'e."to"', 'e.cc'];
    final anyRole =
        '(${columns.map((c) => '$c LIKE ? COLLATE NOCASE').join(' OR ')})';
    List<Object?> valueFor(QueryFilter f) =>
        List.filled(columns.length, '%${f.value}%');

    final groups = <String?, List<QueryFilter>>{};
    for (final f in all.where((f) => !f.negated)) {
      groups.putIfAbsent(f.sourceText, () => []).add(f);
    }
    for (final group in groups.values) {
      final ors = List.filled(group.length, anyRole).join(' OR ');
      where.add(group.length == 1 ? ors : '($ors)');
      for (final f in group) {
        params.addAll(valueFor(f));
      }
    }

    // Exclusions AND, for the same reason they do everywhere else: "not with
    // mike and not with sarah" excludes both, and OR'ing it would excuse any
    // message that merely lacked one of them.
    for (final f in all.where((f) => f.negated)) {
      where.add('NOT $anyRole');
      params.addAll(valueFor(f));
    }
  }

  /// Repeats of one field OR together; negations AND.
  ///
  /// `from:a from:b` means "from either", not "from both" — no message has two
  /// senders, so AND'ing them can only ever return nothing. That was the
  /// documented contract on [ParsedQuery.filtersFor] and on the parser's own
  /// test from the start, but this method AND'd anyway; it went unnoticed while
  /// nothing generated repeats. Person resolution does: one name legitimately
  /// resolves to every address that person uses, and this archive has people
  /// with three.
  ///
  /// Negations keep AND semantics, and must. `-from:a -from:b` means exclude
  /// both, and `NOT(a) OR NOT(b)` is true for almost every row — an exclusion
  /// that OR'd would quietly stop excluding anything.
  static void _addLike(
    ParsedQuery query,
    FilterField field,
    String column,
    List<String> where,
    List<Object?> params,
  ) {
    final all = query.filtersFor(field);
    if (all.isEmpty) return;

    final clause = '$column LIKE ? COLLATE NOCASE';
    final positive = all.where((f) => !f.negated).toList();
    if (positive.isNotEmpty) {
      final ors = List.filled(positive.length, clause).join(' OR ');
      where.add(positive.length == 1 ? ors : '($ors)');
      params.addAll(positive.map((f) => '%${f.value}%'));
    }
    for (final f in all.where((f) => f.negated)) {
      where.add('NOT ($clause)');
      params.add('%${f.value}%');
    }
  }

  static void _addJoinTable(
    ParsedQuery query,
    FilterField field,
    String subquery,
    List<String> where,
    List<Object?> params,
  ) {
    for (final f in query.filtersFor(field)) {
      where.add('f.id ${f.negated ? 'NOT IN' : 'IN'} ($subquery)');
      params.add(f.value);
    }
  }

  /// Builds the `near:` predicate: a radius around a resolved place, OR'd with
  /// a vision-detected landmark of the same name.
  ///
  /// OR'd rather than either-or because they answer different questions about
  /// the same word. `near:rome` should return both the photos whose GPS puts
  /// them in Rome and the photos where the model recognised a Roman landmark —
  /// and on this archive the overlap is small, since only ~10% of images carry
  /// GPS at all and none of the cloud or email sources do.
  ///
  /// A filter reaching here that carries no coordinates is a landmark-only
  /// term: `NearResolver` has already dropped the ones nothing could resolve.
  static void _addNear(
    ParsedQuery query,
    List<String> where,
    List<Object?> params,
  ) {
    for (final f in query.filtersFor(FilterField.near)) {
      final alternatives = <String>[
        'f.id IN (SELECT file_id FROM file_landmarks '
            'WHERE landmark LIKE ? COLLATE NOCASE)',
      ];
      params.add(f.value);

      if (f.hasCoordinates) {
        final lat = f.latitude!;
        final lng = f.longitude!;
        final radiusKm = (f.radiusKm ?? defaultRadiusKm).toDouble();
        final box = GeoRadius.boundingBox(lat, lng, radiusKm);

        // The bounding box is what makes this cheap — it is an index range on
        // (latitude, longitude), and it drops almost everything before a single
        // trig function runs. The haversine that follows is what makes it
        // correct, since a rectangle in degrees always over-covers a circle in
        // kilometres.
        alternatives.add(
          '(f.latitude BETWEEN ? AND ? AND f.longitude BETWEEN ? AND ? '
          'AND ${GeoRadius.haversineSql('f.latitude', 'f.longitude')} <= ?)',
        );
        params.addAll([
          box.minLatitude,
          box.maxLatitude,
          box.minLongitude,
          box.maxLongitude,
          ...GeoRadius.haversineParams(lat, lng),
          radiusKm,
        ]);
      }

      final clause = '(${alternatives.join(' OR ')})';
      where.add(f.negated ? 'NOT $clause' : clause);
    }
  }

  static void _addDateRange(
    ParsedQuery query,
    String column,
    List<String> where,
    List<Object?> params,
  ) {
    for (final f in query.filtersFor(FilterField.after)) {
      if (f.dateValue == null) continue;
      where.add('$column >= ?');
      params.add(f.dateValue!.millisecondsSinceEpoch);
    }
    for (final f in query.filtersFor(FilterField.before)) {
      if (f.dateValue == null) continue;
      where.add('$column < ?');
      params.add(f.dateValue!.millisecondsSinceEpoch);
    }
  }

  static void _addCollection(
    ParsedQuery query,
    String column,
    List<String> where,
    List<Object?> params,
  ) {
    for (final f in query.filtersFor(FilterField.in_)) {
      const sub = 'SELECT id FROM collections WHERE name LIKE ? COLLATE NOCASE';
      where.add('$column ${f.negated ? 'NOT IN' : 'IN'} ($sub)');
      params.add('%${f.value}%');
    }
  }

  static String? _contentTypePredicate(String value) {
    switch (value) {
      case 'image':
      case 'photo':
        return "(f.content_type LIKE 'image/%' "
            "OR f.content_type = 'application/image')";
      case 'video':
        return "f.content_type LIKE 'video/%'";
      case 'pdf':
        return "f.content_type LIKE '%pdf%'";
      case 'document':
      case 'doc':
        return "(f.content_type LIKE '%pdf%' "
            "OR f.content_type LIKE '%word%' "
            "OR f.content_type LIKE 'text/%')";
      default:
        return null;
    }
  }
}
