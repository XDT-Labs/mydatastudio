import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/rank_fusion.dart';
import 'package:mydatastudio/modules/search/services/result_ranking.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';

/// Merges the lexical and semantic passes into one ranking.
///
/// The two retrievers answer different questions — "which rows contain these
/// words" and "which rows mean roughly this" — and their scores are not on
/// comparable scales and never will be. RRF consumes only rank positions, so
/// there is nothing to normalise and nothing to re-tune as the archive grows.
///
/// Tier and recency are applied *after* fusion, as multipliers. That ordering
/// matters: a favourited photo should be able to beat a marginally better
/// textual match, which is the point of the tier boost, and it can only do that
/// if it multiplies a fused score rather than one retriever's raw one.
class HybridRanker {
  /// Deliberately flat. Weighting one retriever up before there is real usage
  /// data would just encode a guess; flat weights make it obvious from the
  /// results which retriever is misbehaving.
  static const retrieverWeights = {'bm25': 1.0, 'vector': 1.0};

  /// Ranks the union of [lexical] and [vector], loading any vector-only hit
  /// that the lexical pass never returned.
  ///
  /// [now] is injectable so recency does not make the ranking depend on when
  /// the test ran.
  static Future<List<SearchResult>> fuse({
    required List<SearchResult> lexical,
    required List<VectorHit> vector,
    required Bm25Retriever loader,
    DateTime? now,
  }) async {
    final byKey = {for (final r in lexical) r.key: r};

    // Everything the vector pass found that the words never would have. This
    // is the half of the search that "find my graduation speech" depends on
    // when the file is called IMG_4471.
    final missingFiles = <String>[];
    final missingEmails = <String>[];
    for (final hit in vector) {
      final key = '${hit.type.name}:${hit.id}';
      if (byKey.containsKey(key)) continue;
      if (hit.type == SearchResultType.file) {
        missingFiles.add(hit.id);
      } else {
        missingEmails.add(hit.id);
      }
    }
    if (missingFiles.isNotEmpty || missingEmails.isNotEmpty) {
      byKey.addAll(
        await loader.loadByIds(fileIds: missingFiles, emailIds: missingEmails),
      );
    }

    final fused = RankFusion.fuse({
      'bm25': [for (final r in lexical) r.key],
      'vector': [for (final h in vector) '${h.type.name}:${h.id}'],
    }, weights: retrieverWeights);

    final ranked = <SearchResult>[];
    for (final entry in fused) {
      // A vector hit whose row has since been deleted simply drops out. The
      // embedding table can outlive its file between a scan and a reap.
      final result = byKey[entry.id];
      if (result == null) continue;
      ranked.add(
        result.withScore(
          ResultRanking.adjust(
            entry.score,
            tier: result.tier,
            date: result.date,
            now: now,
          ),
        ),
      );
    }

    // Re-sorted because the multipliers can and should reorder the fused list —
    // that is what applying them is for.
    ranked.sort((a, b) => b.score.compareTo(a.score));
    return ranked;
  }
}
