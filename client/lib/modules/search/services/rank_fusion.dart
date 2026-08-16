/// Reciprocal Rank Fusion for merging several independently-ranked result
/// lists (e.g. lexical FTS + vector similarity) into one ranking.
///
/// RRF only looks at each document's rank *position*, never the retriever's
/// raw score — that's the point of it. BM25 scores and cosine similarities
/// live on incomparable scales, so averaging them directly would let
/// whichever retriever happens to produce bigger numbers dominate. Rank is
/// the one thing every retriever can be compared on.
class RankFusion {
  /// Standard RRF constant, per the original paper (Cormack et al., 2009).
  /// Large relative to typical result-list lengths so no single retriever's
  /// #1 pick can swamp the sum on its own — a document two retrievers agree
  /// on is meant to beat one retriever's single best guess.
  static const int k = 60;

  /// Fuses several independently-ranked lists of ids into one ranking.
  ///
  /// [rankedLists] maps a retriever name to its results in rank order (best
  /// first). [weights] maps the same names to a multiplier; a name absent
  /// from [weights] defaults to 1.0.
  ///
  /// Returns ids ordered best-first, each with its accumulated score.
  static List<FusedRank> fuse(
    Map<String, List<String>> rankedLists, {
    Map<String, double> weights = const {},
    int k = RankFusion.k,
  }) {
    // id -> (retriever -> 0-based rank), accumulated across every retriever
    // before any score is computed, so ranks are recorded even for a
    // zero-weighted retriever (weight only affects the score, per the spec).
    final ranksById = <String, Map<String, int>>{};

    for (final entry in rankedLists.entries) {
      final retriever = entry.key;
      // A document's rank is where it *first* appears in this retriever's
      // list. A later duplicate (upstream de-dup bug, or a doc matching two
      // clauses of the same query) must not overwrite that with a worse rank
      // or let the retriever count the same document twice.
      final seen = <String>{};
      var rank = 0;
      for (final id in entry.value) {
        if (!seen.add(id)) continue;
        ranksById.putIfAbsent(id, () => {})[retriever] = rank;
        rank++;
      }
    }

    final fused =
        ranksById.entries.map((entry) {
          final id = entry.key;
          final ranks = entry.value;
          var score = 0.0;
          for (final r in ranks.entries) {
            final weight = weights[r.key] ?? 1.0;
            // The RRF formula is defined over 1-based rank. Ranks are stored
            // 0-based above (so a caller reading [FusedRank.ranks] sees "how
            // many results beat this one", the natural index into the source
            // list) — the `+ 1` converts back to 1-based at the one place the
            // distinction matters. Scoring off the stored value directly is the
            // classic RRF bug: it hands the top result 1/k instead of 1/(k+1),
            // silently overweighting every retriever's first pick.
            score += weight / (k + r.value + 1);
          }
          return FusedRank(id: id, score: score, ranks: ranks);
        }).toList();

    fused.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // Deterministic tiebreak: two ids with an identical fused score must
      // always land in the same order, or re-running an identical query
      // would reshuffle results for no visible reason.
      return a.id.compareTo(b.id);
    });

    return fused;
  }
}

/// One fused result: an id's combined RRF score, plus which retrievers found
/// it and at what rank.
class FusedRank {
  final String id;
  final double score;

  /// Which retrievers contributed, and at what 0-based rank. Kept so a
  /// result can explain itself, and so a misbehaving retriever (e.g. one
  /// that's stopped returning a document it always used to) is visible in
  /// tests instead of only showing up as a score drift.
  final Map<String, int> ranks;

  const FusedRank({required this.id, required this.score, required this.ranks});
}
