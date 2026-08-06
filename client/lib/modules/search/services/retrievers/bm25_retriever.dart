import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';

/// Lexical retrieval over the FTS5 indexes, ranked by `bm25()`.
///
/// Two things this deliberately does not do. It does not fold hard filters
/// into the score — they become `WHERE` clauses, so `from:bob` makes mail from
/// anyone else impossible rather than merely unlikely. And it does not require
/// free text: a query that is nothing but filters is a legitimate browse
/// ("everything from this person"), so it falls through to a filter-only scan
/// ordered by date instead of returning nothing.
class Bm25Retriever {
  final AppDatabase db;

  Bm25Retriever(this.db);

  /// Column weights. Subject and file name carry far more signal per word than
  /// a body does, and an unweighted bm25 buries an exact subject-line match
  /// under any long message that repeats the term.
  static const _emailWeights = '10.0, 3.0, 3.0, 1.0, 1.0';
  static const _fileWeights = '3.0, 1.0, 5.0';

  Future<SearchResults> search(ParsedQuery query, {int limit = 100}) async {
    final wantsEmails = _sourceWanted(query, SearchResultType.email);
    final wantsFiles = _sourceWanted(query, SearchResultType.file);

    final match = _toMatchExpression(query.freeText);

    final emails =
        wantsEmails
            ? await _searchEmails(query, match, limit)
            : <SearchResult>[];
    final files =
        wantsFiles ? await _searchFiles(query, match, limit) : <SearchResult>[];

    // Interleaved by rank rather than grouped by type: grouping would bury the
    // best answer under a section header, and a photo query should lead with
    // photos because they scored highest, not because a tab was selected.
    final merged = [...emails, ...files]
      ..sort((a, b) => b.score.compareTo(a.score));

    return SearchResults(
      results: merged.take(limit).toList(),
      emailCount: emails.length,
      fileCount: files.length,
      truncated: merged.length > limit,
    );
  }

  /// Whether [type] should be queried at all.
  ///
  /// `type:` selects a *source*, not a row predicate — `type:email` must not
  /// merely rank files lower, it must exclude them. A negated `-type:email`
  /// inverts that.
  bool _sourceWanted(ParsedQuery query, SearchResultType type) {
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

  Future<List<SearchResult>> _searchEmails(
    ParsedQuery query,
    String? match,
    int limit,
  ) async {
    final where = <String>['e.is_deleted = 0'];
    final params = <Object?>[];

    _addLike(query, FilterField.from, 'e."from"', where, params);
    _addLike(query, FilterField.to, 'e."to"', where, params);
    _addLike(query, FilterField.cc, 'e.cc', where, params);
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

    // A `tag:`/`near:` query is about files; mail cannot satisfy it, and
    // returning mail anyway would look like the filter was ignored.
    if (query.filtersFor(FilterField.tag).any((f) => !f.negated) ||
        query.filtersFor(FilterField.near).any((f) => !f.negated)) {
      return const [];
    }

    final rows =
        match != null
            ? await db.select(
              '''
            SELECT e.id, e.subject, e."from", e.date, e.snippet,
                   e.collection_id, bm25(emails_fts, $_emailWeights) AS score
            FROM emails_fts
            JOIN emails e ON e.rowid = emails_fts.rowid
            WHERE emails_fts MATCH ? AND ${where.join(' AND ')}
            ORDER BY score ASC
            LIMIT ?
            ''',
              [match, ...params, limit],
            )
            : await db.select(
              '''
            SELECT e.id, e.subject, e."from", e.date, e.snippet,
                   e.collection_id, 0.0 AS score
            FROM emails e
            WHERE ${where.join(' AND ')}
            ORDER BY e.date DESC
            LIMIT ?
            ''',
              [...params, limit],
            );

    return rows.map((row) {
      final date = row['date'] as int?;
      return SearchResult(
        id: row['id'] as String,
        type: SearchResultType.email,
        title:
            (row['subject'] as String?)?.trim().isNotEmpty == true
                ? row['subject'] as String
                : '(no subject)',
        subtitle: row['from'] as String?,
        snippet: row['snippet'] as String?,
        date: date == null ? null : DateTime.fromMillisecondsSinceEpoch(date),
        score: _normalizeScore(row['score']),
        collectionId: row['collection_id'] as String?,
      );
    }).toList();
  }

  Future<List<SearchResult>> _searchFiles(
    ParsedQuery query,
    String? match,
    int limit,
  ) async {
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
    // Landmark matching only. The gazetteer + haversine radius lands in
    // Phase 3; until then a place name that is not a recognised landmark
    // falls through to free text rather than silently matching nothing.
    _addJoinTable(
      query,
      FilterField.near,
      'SELECT file_id FROM file_landmarks WHERE landmark LIKE ? COLLATE NOCASE',
      where,
      params,
    );

    for (final f in query.filtersFor(FilterField.type)) {
      final predicate = _contentTypePredicate(f.value.toLowerCase());
      if (predicate == null) continue;
      where.add(f.negated ? 'NOT ($predicate)' : predicate);
    }

    // Mail-only fields cannot be satisfied by a file.
    if (query.filtersFor(FilterField.from).any((f) => !f.negated) ||
        query.filtersFor(FilterField.to).any((f) => !f.negated) ||
        query.filtersFor(FilterField.cc).any((f) => !f.negated) ||
        query.filtersFor(FilterField.has).any((f) => !f.negated) ||
        query.filtersFor(FilterField.is_).any((f) => !f.negated)) {
      return const [];
    }

    final rows =
        match != null
            ? await db.select(
              '''
            SELECT f.id, f.name, f.path, f.description, f.content_type,
                   f.date_created, f.thumbnail, f.collection_id,
                   bm25(files_fts, $_fileWeights) AS score
            FROM files_fts
            JOIN files f ON f.rowid = files_fts.rowid
            WHERE files_fts MATCH ? AND ${where.join(' AND ')}
            ORDER BY score ASC
            LIMIT ?
            ''',
              [match, ...params, limit],
            )
            : await db.select(
              '''
            SELECT f.id, f.name, f.path, f.description, f.content_type,
                   f.date_created, f.thumbnail, f.collection_id, 0.0 AS score
            FROM files f
            WHERE ${where.join(' AND ')}
            ORDER BY f.date_created DESC
            LIMIT ?
            ''',
              [...params, limit],
            );

    return rows.map((row) {
      final date = row['date_created'] as int?;
      return SearchResult(
        id: row['id'] as String,
        type: SearchResultType.file,
        title: row['name'] as String? ?? '(unnamed)',
        subtitle: row['path'] as String?,
        snippet: row['description'] as String?,
        date: date == null ? null : DateTime.fromMillisecondsSinceEpoch(date),
        score: _normalizeScore(row['score']),
        collectionId: row['collection_id'] as String?,
        contentType: row['content_type'] as String?,
        thumbnail: row['thumbnail'] as String?,
      );
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Filter builders. Repeats of one field OR together; distinct fields AND.
  // ---------------------------------------------------------------------------

  void _addLike(
    ParsedQuery query,
    FilterField field,
    String column,
    List<String> where,
    List<Object?> params,
  ) {
    for (final f in query.filtersFor(field)) {
      final clause = '$column LIKE ? COLLATE NOCASE';
      where.add(f.negated ? 'NOT ($clause)' : clause);
      params.add('%${f.value}%');
    }
  }

  void _addJoinTable(
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

  void _addDateRange(
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

  void _addCollection(
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

  String? _contentTypePredicate(String value) {
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

  /// Builds a syntactically safe FTS5 `MATCH` expression, or null when there
  /// is nothing to match on.
  ///
  /// User input reaches FTS5 as a *query language*, not a literal: a trailing
  /// `AND`, a stray `"` or a bare `*` is a syntax error that would surface as
  /// a thrown exception mid-typing. Quoting each token turns every term into a
  /// literal phrase, which both removes the syntax surface and gives the
  /// implicit-AND behaviour a user expects from a search box.
  static String? _toMatchExpression(String freeText) {
    final tokens =
        freeText
            .split(RegExp(r'\s+'))
            .map((t) => t.replaceAll(RegExp(r'[^\w\s@.\-]', unicode: true), ''))
            .where((t) => t.isNotEmpty)
            .toList();
    if (tokens.isEmpty) return null;
    return tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
  }

  /// Flips bm25's sign so higher means better everywhere above this line.
  static double _normalizeScore(Object? raw) {
    final value = (raw as num?)?.toDouble() ?? 0.0;
    return -value;
  }
}
