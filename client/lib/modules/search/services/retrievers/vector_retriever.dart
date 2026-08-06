import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/search_filters.dart';

/// Turns the query's free text into an embedding, or null when it cannot.
///
/// Null is a normal outcome, not an error: the model lives in a subprocess that
/// may not be up yet, may not have the embedding model downloaded, and is not
/// worth blocking a keyword search on.
typedef QueryEmbedder = Future<List<double>?> Function(String text);

/// One vector-pass candidate.
class VectorHit {
  final SearchResultType type;
  final String id;

  /// Monotonic in similarity, higher is better.
  ///
  /// Comparable *within* one search and not across searches or modes: Mode A
  /// reports a true cosine, Mode B a linear transform of the extension's
  /// distance. Only the rank order reaches rank fusion, which is the whole
  /// reason RRF was chosen over score blending.
  final double similarity;

  const VectorHit({
    required this.type,
    required this.id,
    required this.similarity,
  });

  @override
  String toString() =>
      'VectorHit(${type.name}, $id, ${similarity.toStringAsFixed(4)})';
}

/// Semantic retrieval over the Qwen3-VL embeddings.
///
/// Runs in one of two modes, and the choice is forced by a property of
/// `vector_full_scan` that is easy to miss: **it cannot be pre-filtered.** It
/// computes a distance against every row in the table and hands back the best
/// N; a `WHERE` on the surrounding query filters that result, not the scan. So
/// with a selective filter the top N is mostly rows the filter then throws
/// away, and a query like `tag:nature sunset` would come back near-empty.
///
/// - **Mode A — filters present.** The filter picks a bounded candidate set,
///   its blobs are read, and cosine is computed in Dart. Exactly filtered, and
///   at 2048 dims a few thousand candidates is a few milliseconds of dot
///   products.
/// - **Mode B — no filters.** Nothing to narrow by, so `vector_full_scan` does
///   the work inside SQLite and returns only the top N — which avoids pulling
///   the whole corpus (8 KB per vector) into Dart.
///
/// Every failure path returns an empty list rather than throwing. Search must
/// keep working when the AI subprocess is down; degrading to lexical-only is a
/// worse search, but a broken search is a worse outcome.
class VectorRetriever {
  final AppDatabase db;
  final QueryEmbedder embed;
  final AppLogger logger = AppLogger(null);

  VectorRetriever(this.db, this.embed);

  /// Candidates returned per source. Deep enough that rank fusion has real
  /// material to work with, shallow enough that nothing past it would have
  /// survived fusion anyway.
  static const candidateLimit = 300;

  /// Ceiling on rows read in Mode A.
  ///
  /// 4,000 vectors is ~32 MB of blobs — the point where reading them stops
  /// being free. Past it the filter set is ranked by recency and its most
  /// recent slice is what gets scored, which is a real (documented) recall
  /// loss on a huge filter set. The measured corpus holds ~4,700 file vectors
  /// in total, so this does not bind today; §12's 50k tripwire is where it
  /// starts to, and where quantised scanning earns its place.
  static const modeACandidateCap = 4000;

  /// Ranked candidates for [query], best first.
  Future<List<VectorHit>> search(
    ParsedQuery query, {
    int limit = candidateLimit,
    SearchResultType? onlySource,
  }) async {
    if (!query.hasFreeText) return const [];

    final List<double>? queryVector;
    try {
      queryVector = await embed(query.freeText);
    } catch (e) {
      logger.d('VectorRetriever: embedding failed, lexical only: $e');
      return const [];
    }
    if (queryVector == null || queryVector.isEmpty) return const [];

    final wantEmails =
        onlySource != SearchResultType.file
            ? SearchFilters.forEmails(query)
            : null;
    final wantFiles =
        onlySource != SearchResultType.email
            ? SearchFilters.forFiles(query)
            : null;

    final hits = <VectorHit>[];
    try {
      if (wantFiles != null) {
        hits.addAll(await _searchFiles(query, wantFiles, queryVector, limit));
      }
      if (wantEmails != null) {
        hits.addAll(await _searchEmails(query, wantEmails, queryVector, limit));
      }
    } catch (e, stackTrace) {
      // Most likely the sqlite_vector extension failing to load, which takes
      // out Mode B only. Lexical results are already on their way regardless.
      logger.w(
        'VectorRetriever: vector pass failed, lexical only: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }

    hits.sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits;
  }

  Future<List<VectorHit>> _searchFiles(
    ParsedQuery query,
    SourceFilter filter,
    List<double> queryVector,
    int limit,
  ) async {
    if (query.hasFilters) {
      final rows = await db.select(
        '''
        SELECT emb.file_id AS id, emb.qwen3_vl_embedding AS v
        FROM files_embeddings emb
        JOIN files f ON f.id = emb.file_id
        WHERE ${filter.sql} AND emb.qwen3_vl_embedding IS NOT NULL
        ORDER BY f.date_created DESC
        LIMIT ?
        ''',
        [...filter.params, modeACandidateCap],
      );
      return _rankInDart(rows, queryVector, SearchResultType.file, limit);
    }

    // The over-fetch is not slack, it is required. A file carries up to two
    // vectors — the image itself and its AI description — and both compete for
    // slots in the scan's raw top-N, so a single photo can occupy two of them
    // before deduplication collapses it back to one.
    final rows = await db.select(
      '''
      SELECT emb.file_id AS id, v.distance AS distance
      FROM files_embeddings emb
      JOIN files f ON f.id = emb.file_id
      JOIN vector_full_scan(
        'files_embeddings', 'qwen3_vl_embedding', vector_as_f32(?), ?
      ) AS v ON emb.rowid = v.rowid
      WHERE ${filter.sql}
      ORDER BY v.distance ASC
      ''',
      [_toJsonArray(queryVector), limit * 5, ...filter.params],
    );
    return _rankFromDistance(rows, SearchResultType.file, limit);
  }

  Future<List<VectorHit>> _searchEmails(
    ParsedQuery query,
    SourceFilter filter,
    List<double> queryVector,
    int limit,
  ) async {
    if (query.hasFilters) {
      final rows = await db.select(
        '''
        SELECT emb.email_id AS id, emb.qwen3_vl_embedding AS v
        FROM emails_embeddings emb
        JOIN emails e ON e.id = emb.email_id
        WHERE ${filter.sql} AND emb.qwen3_vl_embedding IS NOT NULL
        ORDER BY e.date DESC
        LIMIT ?
        ''',
        [...filter.params, modeACandidateCap],
      );
      return _rankInDart(rows, queryVector, SearchResultType.email, limit);
    }

    final rows = await db.select(
      '''
      SELECT emb.email_id AS id, v.distance AS distance
      FROM emails_embeddings emb
      JOIN emails e ON e.id = emb.email_id
      JOIN vector_full_scan(
        'emails_embeddings', 'qwen3_vl_embedding', vector_as_f32(?), ?
      ) AS v ON emb.rowid = v.rowid
      WHERE ${filter.sql}
      ORDER BY v.distance ASC
      ''',
      [_toJsonArray(queryVector), limit * 2, ...filter.params],
    );
    return _rankFromDistance(rows, SearchResultType.email, limit);
  }

  /// Mode A: cosine against every candidate blob, deduplicated to the best hit
  /// per id.
  ///
  /// Deduplication happens before the limit is applied, not after. A file with
  /// both an image vector and a description vector would otherwise take two of
  /// the returned slots and crowd out a genuinely different result.
  List<VectorHit> _rankInDart(
    List<Map<String, Object?>> rows,
    List<double> queryVector,
    SearchResultType type,
    int limit,
  ) {
    final query = Float32List.fromList(queryVector);
    final queryNorm = _norm(query);
    if (queryNorm == 0) return const [];

    final best = <String, double>{};
    for (final row in rows) {
      final blob = row['v'];
      if (blob is! Uint8List) continue;
      final vector = _asFloat32(blob);
      if (vector.length != query.length) continue;

      final similarity = _cosine(query, vector, queryNorm);
      final id = row['id'] as String;
      final existing = best[id];
      if (existing == null || similarity > existing) best[id] = similarity;
    }

    final hits = [
      for (final entry in best.entries)
        VectorHit(type: type, id: entry.key, similarity: entry.value),
    ]..sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits.take(limit).toList();
  }

  /// Mode B: the extension already ranked these; collapse duplicates and map
  /// distance onto the same higher-is-better orientation Mode A reports.
  List<VectorHit> _rankFromDistance(
    List<Map<String, Object?>> rows,
    SearchResultType type,
    int limit,
  ) {
    final best = <String, double>{};
    for (final row in rows) {
      final distance = (row['distance'] as num?)?.toDouble();
      if (distance == null) continue;
      final similarity = 1.0 - distance / 2.0;
      final id = row['id'] as String;
      final existing = best[id];
      if (existing == null || similarity > existing) best[id] = similarity;
    }

    final hits = [
      for (final entry in best.entries)
        VectorHit(type: type, id: entry.key, similarity: entry.value),
    ]..sort((a, b) => b.similarity.compareTo(a.similarity));
    return hits.take(limit).toList();
  }

  /// Reads a stored vector without copying it.
  ///
  /// The offset arguments are load-bearing: a `Uint8List` handed back by the
  /// driver is often a window onto a larger buffer, and `Float32List.view(
  /// blob.buffer)` alone would read from the start of that buffer rather than
  /// the start of this row's vector.
  static Float32List _asFloat32(Uint8List blob) {
    return Float32List.view(
      blob.buffer,
      blob.offsetInBytes,
      blob.lengthInBytes ~/ Float32List.bytesPerElement,
    );
  }

  static double _cosine(Float32List a, Float32List b, double aNorm) {
    var dot = 0.0;
    var bSquared = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      bSquared += b[i] * b[i];
    }
    if (bSquared == 0) return 0.0;
    // Divided out rather than assumed away. The embeddings *should* be unit
    // vectors, in which case this is a no-op — but a query whose ranking
    // silently depends on that being true would be a bad thing to debug later.
    return dot / (aNorm * math.sqrt(bSquared));
  }

  static double _norm(Float32List v) {
    var sum = 0.0;
    for (var i = 0; i < v.length; i++) {
      sum += v[i] * v[i];
    }
    return math.sqrt(sum);
  }

  /// The JSON-array form `vector_as_f32()` accepts, matching the existing
  /// embedding write path in `DatabaseRepository`.
  static String _toJsonArray(List<double> vector) => '[${vector.join(',')}]';
}
