import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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

  /// Ceiling on candidates returned per source — a guard against unbounded
  /// memory, not the relevance gate. [similarityFloorRatio] is the gate.
  ///
  /// It has to be a ceiling rather than a cap, because `SearchService` holds
  /// the whole fused list and pages *within* it: whatever is dropped here is
  /// not "page two", it is unreachable. At 300 an archive holding 1,200 real
  /// matches could surface only a quarter of them, and nothing would tell the
  /// user the rest existed.
  ///
  /// Raising it is close to free. Mode A has already read and scored up to
  /// [modeACandidateCap] blobs before this applies, so a larger slice costs no
  /// extra I/O. Mode B passes it to `vector_full_scan`, which computes a
  /// distance for every row regardless — the bound only limits how many
  /// `(rowid, distance)` pairs come back, and no blobs travel with them.
  static const candidateLimit = 2000;

  /// How far above its modality's *background* similarity a hit must score to
  /// survive, as a fraction of the distance from that background to the best
  /// hit. The floor is `median + ratio * (best - median)`.
  ///
  /// The baseline is the whole point, and anchoring at zero instead was a real
  /// bug. Cosine has no meaningful origin here: a text query scores every
  /// email somewhat highly simply because both sides are text. Measured on
  /// this archive, the *median* email scores 0.334 against an arbitrary query
  /// while the median photo scores 0.205. So `0.75 * best` is genuinely
  /// selective for photographs and barely above ordinary for mail — searching
  /// `white dog` kept 31 emails, of which one was about dogs and the rest were
  /// "Today is the day!", "Happy 4/20!" and a run of word-trivia newsletters.
  /// Recentred on the median it keeps exactly the one about dogs.
  ///
  /// It sharpens real mail queries rather than trading them away:
  /// `flight confirmation` goes from 310 emails to 6, and those 6 are the
  /// eTickets.
  ///
  /// Fixing this in the retriever matters more than it looks, because
  /// `HybridRanker` fuses each modality as its own ranked list: whatever
  /// survives here becomes rank 1 of `vector_email` and is therefore fused as
  /// an equal of the best photograph, however irrelevant it is.
  ///
  /// Which is also the limit of what this can do. The floor is derived from
  /// the modality's own best hit, so a modality always contributes *something*
  /// — it cannot recognise that it has nothing to say. That is not a gap
  /// waiting on a better statistic: measured across six queries,
  /// `(top - median) / (p90 - median)` for mail ranged 2.33 to 4.76 and was
  /// **highest** on the queries where mail was least relevant, so the shape of
  /// the distribution does not reveal whether the top hit means anything.
  /// Keeping the residual one or two out of the first page is a ranking
  /// concern, not a retrieval one.
  static const similarityFloorRatio = 0.75;

  /// Below this many candidates the floor is not applied at all.
  ///
  /// The floor reads the median as an estimate of "what this query scores
  /// against nothing in particular", and that estimate is only meaningful when
  /// most of the sample *is* nothing in particular. On a handful of candidates
  /// the median is one of the answers: at three hits the median is the second,
  /// so the floor lands above it and every search returns exactly one result.
  ///
  /// It also keeps the floor away from the case it reasons badly about — a
  /// selective filter, where the candidate set is already all relevant and
  /// there is no background to stand out from. `tag:nature` narrowing to a
  /// dozen photos should show a dozen photos.
  static const minimumCandidatesForFloor = 50;

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

    // Sorted globally only so the return value has a defined order. Callers
    // must not read across sources from it: a text query scores mail
    // (same-modal) systematically higher than photos (cross-modal), so this
    // ordering says more about which encoder produced a vector than about
    // relevance. HybridRanker partitions by source before fusing, and this
    // sort is what leaves each partition correctly ordered within itself.
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
    return floorAndCap(hits, limit);
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
    return floorAndCap(hits, limit);
  }

  /// Drops hits that do not stand far enough above the background, then
  /// applies the ceiling.
  ///
  /// [hits] must already be sorted best-first and hold a single modality.
  /// Both the best score and the median are read from it, so mixing sources
  /// here would measure photographs against a scale set by mail — the failure
  /// `HybridRanker`'s split vector lists exist to prevent. Each caller handles
  /// one [SearchResultType], which is what satisfies this.
  ///
  /// The median is taken over what was retrieved rather than over the table.
  /// In Mode A that is the whole filtered candidate set, so it is the real
  /// median. In Mode B it is the top N the extension returned; while N covers
  /// the corpus — it does today, at 2,000 against ~4,700 file and ~1,300 email
  /// vectors, because the ceiling exceeds both — that is also the real median.
  /// Past that point the sample skews high, which biases the floor *upward*
  /// and prunes harder. §12's 50k tripwire is where that starts to matter.
  ///
  /// A spread of zero or less means every candidate scored alike and there is
  /// no signal to separate: scaling would then invert the comparison, since
  /// 0.75 of a negative number is larger than the number. The floor is skipped
  /// in that case and the ceiling alone applies.
  @visibleForTesting
  static List<VectorHit> floorAndCap(List<VectorHit> hits, int limit) {
    if (hits.isEmpty) return const [];
    if (hits.length < minimumCandidatesForFloor) {
      return hits.take(limit).toList();
    }

    final best = hits.first.similarity;
    final baseline = hits[hits.length ~/ 2].similarity;
    final spread = best - baseline;
    if (spread <= 0) return hits.take(limit).toList();

    final floor = baseline + spread * similarityFloorRatio;
    final kept = <VectorHit>[];
    for (final hit in hits) {
      // Sorted, so the first hit below the floor ends it.
      if (hit.similarity < floor) break;
      kept.add(hit);
      if (kept.length == limit) break;
    }
    return kept;
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
