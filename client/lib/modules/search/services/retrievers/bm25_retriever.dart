import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/result_ranking.dart';
import 'package:mydatastudio/modules/search/services/search_filters.dart';

/// Lexical retrieval over the FTS5 indexes, ranked by `bm25()`.
///
/// Two things this deliberately does not do. It does not fold hard filters
/// into the score — they become `WHERE` clauses (see [SearchFilters]), so
/// `from:bob` makes mail from anyone else impossible rather than merely
/// unlikely. And it does not require free text: a query that is nothing but
/// filters is a legitimate browse ("everything from this person"), so it falls
/// through to a filter-only scan ordered by date instead of returning nothing.
class Bm25Retriever {
  final AppDatabase db;

  Bm25Retriever(this.db);

  /// Column weights. Subject and file name carry far more signal per word than
  /// a body does, and an unweighted bm25 buries an exact subject-line match
  /// under any long message that repeats the term.
  static const _emailWeights = '10.0, 3.0, 3.0, 1.0, 1.0';
  static const _fileWeights = '3.0, 1.0, 5.0';

  /// Rows fetched per page.
  ///
  /// Modest because the list pages as it scrolls — the first screenful should
  /// arrive fast and the rest follows on demand.
  static const pageSize = 200;

  /// Fetches one page of results.
  ///
  /// [emailOffset]/[fileOffset] are the per-source cursors carried by the
  /// previous page (see [SearchResults.emailOffset]). [onlySource] restricts
  /// retrieval to one archive, which is what selecting a facet does: it
  /// re-queries rather than slicing the loaded page, so picking "Emails 112"
  /// can reach all 112 rather than only those that fit alongside the files.
  Future<SearchResults> search(
    ParsedQuery query, {
    int limit = pageSize,
    int emailOffset = 0,
    int fileOffset = 0,
    SearchResultType? onlySource,
  }) async {
    final match = toMatchExpression(query.freeText);

    // Built without regard to [onlySource]: the counts below feed the facet
    // bar, which has to keep reporting every archive's total even while one is
    // selected. Zeroing the others would strand a user who picked a facet with
    // no results — the control they need to leave it would show 0 too.
    final emailWhere = SearchFilters.forEmails(query);
    final fileWhere = SearchFilters.forFiles(query);

    // Counted separately rather than inferred from the returned rows. A source
    // that filled its page is indistinguishable from one that happened to
    // return exactly that many, and these totals are what every count in the
    // UI reports.
    final emailTotal =
        emailWhere == null
            ? 0
            : await _count('emails', 'emails_fts', 'e', emailWhere, match);
    final fileTotal =
        fileWhere == null
            ? 0
            : await _count('files', 'files_fts', 'f', fileWhere, match);

    // Only row retrieval honours [onlySource]. Counting is unrestricted.
    final fetchEmails =
        emailWhere != null && onlySource != SearchResultType.file;
    final fetchFiles =
        fileWhere != null && onlySource != SearchResultType.email;

    final emails =
        !fetchEmails
            ? <SearchResult>[]
            : await _searchEmails(emailWhere, match, limit, emailOffset);
    final files =
        !fetchFiles
            ? <SearchResult>[]
            : await _searchFiles(fileWhere, match, limit, fileOffset);

    // Interleaved by rank rather than grouped by type: grouping would bury the
    // best answer under a section header, and a photo query should lead with
    // photos because they scored highest, not because a tab was selected.
    //
    // A query that named a kind of thing ("family photos") lifts that kind
    // here too, not only in the fused path — otherwise the ordering the user
    // asked for would silently disappear whenever the AI subprocess is down.
    final merged =
        [...emails, ...files]
            .map(
              (r) => r.withScore(
                r.score *
                    (query.prefers(r.modality) == true
                        ? ResultRanking.modalityPreferenceBoost
                        : 1.0),
              ),
            )
            .toList()
          ..sort((a, b) => b.score.compareTo(a.score));
    final page = merged.take(limit).toList();

    // Each cursor advances by however many rows of that source survived the
    // merge — exactly what this page consumed from it.
    return SearchResults(
      results: page,
      emailTotal: emailTotal,
      fileTotal: fileTotal,
      emailOffset: emailOffset + page.where((r) => r.isEmail).length,
      fileOffset: fileOffset + page.where((r) => r.isFile).length,
      // Carried so `hasMore` only considers sources actually being fetched.
      // Without it a restricted search would see an untouched cursor against a
      // full total and ask for pages forever.
      sourceFilter: onlySource,
    );
  }

  /// Total rows matching [where], ignoring the result limit.
  Future<int> _count(
    String table,
    String ftsTable,
    String alias,
    SourceFilter where,
    String? match,
  ) async {
    final rows =
        match != null
            ? await db.select(
              'SELECT COUNT(*) AS c FROM $ftsTable '
              'JOIN $table AS $alias ON $alias.rowid = $ftsTable.rowid '
              'WHERE $ftsTable MATCH ? AND ${where.sql}',
              [match, ...where.params],
            )
            : await db.select(
              'SELECT COUNT(*) AS c FROM $table AS $alias WHERE ${where.sql}',
              where.params,
            );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<List<SearchResult>> _searchEmails(
    SourceFilter filter,
    String? match,
    int limit,
    int offset,
  ) async {
    final rows =
        match != null
            ? await db.select(
              '''
            SELECT $_emailColumns,
                   bm25(emails_fts, $_emailWeights) AS score
            FROM emails_fts
            JOIN emails e ON e.rowid = emails_fts.rowid
            WHERE emails_fts MATCH ? AND ${filter.sql}
            ORDER BY score ASC
            LIMIT ? OFFSET ?
            ''',
              [match, ...filter.params, limit, offset],
            )
            : await db.select(
              '''
            SELECT $_emailColumns, 0.0 AS score
            FROM emails e
            WHERE ${filter.sql}
            ORDER BY e.date DESC
            LIMIT ? OFFSET ?
            ''',
              [...filter.params, limit, offset],
            );

    return rows.map(emailFromRow).toList();
  }

  Future<List<SearchResult>> _searchFiles(
    SourceFilter filter,
    String? match,
    int limit,
    int offset,
  ) async {
    final rows =
        match != null
            ? await db.select(
              '''
            SELECT $_fileColumns,
                   bm25(files_fts, $_fileWeights) AS score
            FROM files_fts
            JOIN files f ON f.rowid = files_fts.rowid
            LEFT JOIN collections c ON c.id = f.collection_id
            WHERE files_fts MATCH ? AND ${filter.sql}
            ORDER BY score ASC
            LIMIT ? OFFSET ?
            ''',
              [match, ...filter.params, limit, offset],
            )
            : await db.select(
              '''
            SELECT $_fileColumns, 0.0 AS score
            FROM files f
            LEFT JOIN collections c ON c.id = f.collection_id
            WHERE ${filter.sql}
            ORDER BY f.date_created DESC
            LIMIT ? OFFSET ?
            ''',
              [...filter.params, limit, offset],
            );

    return rows.map(fileFromRow).toList();
  }

  /// Loads results by id, for hits the vector pass found that the lexical pass
  /// never returned.
  ///
  /// Fusion ranks the union of both retrievers' lists, so a semantically strong
  /// match containing none of the query's words has to be materialised from
  /// somewhere — and it has to come back shaped exactly like a lexical hit,
  /// tier included, or the same photo would score differently depending on
  /// which retriever happened to surface it.
  Future<Map<String, SearchResult>> loadByIds({
    List<String> fileIds = const [],
    List<String> emailIds = const [],
  }) async {
    final loaded = <String, SearchResult>{};

    if (fileIds.isNotEmpty) {
      final rows = await db.select(
        'SELECT $_fileColumns, 0.0 AS score FROM files f '
        'LEFT JOIN collections c ON c.id = f.collection_id '
        'WHERE f.id IN (${_placeholders(fileIds.length)})',
        fileIds,
      );
      for (final row in rows) {
        final result = fileFromRow(row);
        loaded[result.key] = result;
      }
    }

    if (emailIds.isNotEmpty) {
      final rows = await db.select(
        'SELECT $_emailColumns, 0.0 AS score FROM emails e '
        'WHERE e.id IN (${_placeholders(emailIds.length)})',
        emailIds,
      );
      for (final row in rows) {
        final result = emailFromRow(row);
        loaded[result.key] = result;
      }
    }

    return loaded;
  }

  /// Which of [ids] the lexical query also matches.
  ///
  /// Used to keep the reported totals exact. A vector hit that BM25 would have
  /// found anyway is already inside `emailTotal`/`fileTotal`; counting it again
  /// as a semantic addition would overstate the result count by however many
  /// the two retrievers agreed on — and a count the user cannot reach by
  /// scrolling is the bug they notice.
  Future<Set<String>> matchingIds(
    ParsedQuery query,
    SearchResultType type,
    List<String> ids,
  ) async {
    final match = toMatchExpression(query.freeText);
    if (ids.isEmpty || match == null) return const {};

    final filter =
        type == SearchResultType.email
            ? SearchFilters.forEmails(query)
            : SearchFilters.forFiles(query);
    if (filter == null) return const {};

    final table = type == SearchResultType.email ? 'emails' : 'files';
    final ftsTable =
        type == SearchResultType.email ? 'emails_fts' : 'files_fts';
    final alias = type == SearchResultType.email ? 'e' : 'f';

    final rows = await db.select(
      'SELECT $alias.id AS id FROM $ftsTable '
      'JOIN $table AS $alias ON $alias.rowid = $ftsTable.rowid '
      'WHERE $ftsTable MATCH ? AND ${filter.sql} '
      'AND $alias.id IN (${_placeholders(ids.length)})',
      [match, ...filter.params, ...ids],
    );
    return {for (final row in rows) row['id'] as String};
  }

  static String _placeholders(int count) => List.filled(count, '?').join(', ');

  static const _fileColumns =
      'f.id, f.name, f.path, f.description, f.content_type, f.date_created, '
      'f.thumbnail, f.collection_id, f.is_favorite, c.scanner, '
      'EXISTS(SELECT 1 FROM album_files af WHERE af.file_id = f.id) AS in_album';

  static const _emailColumns =
      'e.id, e.subject, e."from", e.date, e.snippet, e.collection_id';

  static SearchResult fileFromRow(Map<String, Object?> row) {
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
      tier: _fileTier(row),
    );
  }

  static SearchResult emailFromRow(Map<String, Object?> row) {
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
  }

  /// Which tier a file's score is multiplied by.
  ///
  /// Favouriting or filing something into an album is the only *explicit*
  /// signal a user ever gives about their own archive, so it outranks
  /// everything else. Below that, where the file came from stands in: a file
  /// on disk or a personal cloud drive was kept deliberately, whereas an
  /// attachment on someone else's mail arrived whether the user wanted it or
  /// not.
  static SourceTier _fileTier(Map<String, Object?> row) {
    final favorite = (row['is_favorite'] as num?)?.toInt() == 1;
    final inAlbum = (row['in_album'] as num?)?.toInt() == 1;
    if (favorite || inAlbum) return SourceTier.curatedByUser;

    final scanner = row['scanner'] as String? ?? '';
    if (scanner.startsWith('email.')) return SourceTier.receivedAttachment;
    return SourceTier.personalArchive;
  }

  /// Builds a syntactically safe FTS5 `MATCH` expression, or null when there
  /// is nothing to match on.
  ///
  /// User input reaches FTS5 as a *query language*, not a literal: a trailing
  /// `AND`, a stray `"` or a bare `*` is a syntax error that would surface as
  /// a thrown exception mid-typing. Quoting each token turns every term into a
  /// literal phrase, which both removes the syntax surface and gives the
  /// implicit-AND behaviour a user expects from a search box.
  static String? toMatchExpression(String freeText) {
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
