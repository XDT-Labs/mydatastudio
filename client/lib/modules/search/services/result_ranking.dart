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

  /// How much naming a kind of thing lifts results of that kind.
  ///
  /// A *preference*, never a constraint. "family photos" should lead with
  /// photographs, but the mail thread where those photos were actually sent
  /// belongs in the results too — and has to stay reachable under the Emails
  /// facet, which a `type:` filter would zero out entirely.
  ///
  /// 1.4x was too small, because of how the fused score it multiplies is
  /// built. An email can appear in *both* the lexical list and its own vector
  /// list, and RRF adds the two contributions: at rank 1 in each that is
  /// 1/61 + 1/61 = 0.033, twice what a photograph found only by the vector
  /// pass can reach. Searching `family photos` on this archive, the leading
  /// marketing mail was in both lists while the family photographs were in
  /// neither's lexical half — 7 of 2,338 files match the word "family", where
  /// 107 emails do. 1.4x could not close a 2x gap, so the photographs lost.
  ///
  /// 3.0x is sized against that worst case rather than guessed. The 11th and
  /// last surviving photo, in the personal-archive tier and old enough to take
  /// the full recency floor, scores 1/71 * 3.0 * 1.2 * 0.75 = 0.038 and clears
  /// the double-listed email's 0.033.
  ///
  /// It stays a preference, not a block sort: the multiplier scales the fused
  /// score, so it lifts the whole photo list without flattening it, and a
  /// genuinely weak photograph stays weak. That same email still beats a photo
  /// at vector rank 300 (0.0075), which is the intended outcome — obvious
  /// family photos first, everything else interleaved on merit.
  static const modalityPreferenceBoost = 3.0;

  /// [fusedScore] scaled by the tier boost, the recency decay, and — when the
  /// query named a kind of thing — the modality preference.
  ///
  /// [matchesPreferredType] is null when the query named no kind at all, which
  /// is not the same as naming one and missing it: with no preference stated
  /// nothing should be lifted or held back.
  static double adjust(
    double fusedScore, {
    required SourceTier tier,
    DateTime? date,
    DateTime? now,
    bool? matchesPreferredType,
  }) {
    final preference =
        matchesPreferredType == true ? modalityPreferenceBoost : 1.0;
    return fusedScore *
        tierMultiplier(tier) *
        recencyMultiplier(date, now: now) *
        preference;
  }
}
