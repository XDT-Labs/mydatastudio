import 'dart:math';

/// How much deliberate human investment an artifact represents. Ordered from
/// strongest signal to weakest.
enum SourceTier {
  /// Favorited, or placed in an album by hand.
  curatedByUser,

  /// Kept on the local filesystem or a personal cloud drive.
  personalArchive,

  /// Mail the user wrote or received. The baseline.
  correspondence,

  /// An attachment on mail someone else sent — their artifact, not the user's.
  receivedAttachment,
}

/// Post-fusion score adjustments applied on top of Reciprocal Rank Fusion.
///
/// RRF only knows how each retriever ranked a result, not what kind of
/// artifact it is or how old it is. These two multipliers layer that back in
/// without touching the fusion math itself.
class ResultRanking {
  /// How much a tier should boost (or discount) a fused score.
  ///
  /// Spans 1.9x top-to-bottom (1.5 / 0.8) — wide enough that tier is the
  /// primary sort signal within a fused score band, with recency below only
  /// breaking ties.
  static double tierMultiplier(SourceTier tier) {
    switch (tier) {
      case SourceTier.curatedByUser:
        return 1.5;
      case SourceTier.personalArchive:
        return 1.2;
      case SourceTier.correspondence:
        return 1.0;
      case SourceTier.receivedAttachment:
        return 0.8;
    }
  }

  /// How much an artifact's age should discount a fused score.
  ///
  /// A missing or future [date] returns 1.0 rather than being treated as
  /// infinitely old: a null date is unknown age, not old age, and a future
  /// date is clock skew or bad EXIF, not a reason to rank something above
  /// everything else.
  ///
  /// The decay itself is `1 / (1 + ln(1 + ageDays / 365))`, floored at 0.75.
  /// The floor is the important part: RRF scores sit in a very narrow band
  /// (adjacent ranks differ by roughly 1.6%), so the unclamped curve — which
  /// reaches 0.26 for a 17-year-old item — would make age the dominant sort
  /// key instead of a mild tiebreak, burying the decades-old artifact a
  /// personal archive exists to hold. Flooring keeps the whole recency spread
  /// to 1.33x, mild next to the 1.9x tier spread above: tier is meant to
  /// dominate, recency is not.
  static double recencyMultiplier(DateTime? date, {DateTime? now}) {
    if (date == null) return 1.0;
    final effectiveNow = now ?? DateTime.now();
    final ageDays = effectiveNow.difference(date).inDays;
    if (ageDays <= 0) return 1.0;
    final decayed = 1 / (1 + log(1 + ageDays / 365));
    return max(decayed, 0.75);
  }

  /// [fusedScore] scaled by both the tier boost and the recency decay.
  static double adjust(
    double fusedScore, {
    required SourceTier tier,
    DateTime? date,
    DateTime? now,
  }) {
    return fusedScore *
        tierMultiplier(tier) *
        recencyMultiplier(date, now: now);
  }
}
