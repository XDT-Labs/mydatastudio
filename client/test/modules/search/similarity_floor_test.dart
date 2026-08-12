import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';

/// A retrieved candidate list: a few real matches on top of the broad
/// background every query scores against.
///
/// The background is not padding. The floor is measured from the median, so a
/// fixture of four hand-picked top hits would describe a corpus that does not
/// exist and would calibrate against itself.
List<VectorHit> corpus({
  required List<double> matches,
  required double background,
  int backgroundCount = 200,
  SearchResultType type = SearchResultType.file,
}) {
  final all = [
    ...matches,
    for (var i = 0; i < backgroundCount; i++) background - i * 0.0001,
  ]..sort((a, b) => b.compareTo(a));
  return [
    for (var i = 0; i < all.length; i++)
      VectorHit(type: type, id: 'r$i', similarity: all[i]),
  ];
}

void main() {
  group('similarity floor', () {
    test('drops the long tail of weak matches', () {
      // The reported symptom: "white dog" returned dogs, then white swans,
      // white shirts, a horse beside something white. Measured on the archive
      // the dogs run 0.68 -> ~0.60 and the swans start at 0.445.
      final kept = VectorRetriever.floorAndCap(
        corpus(
          matches: [0.68, 0.66, 0.63, 0.60, 0.445, 0.42, 0.40],
          background: 0.205,
        ),
        2000,
      );

      expect(kept.map((h) => h.similarity), [0.68, 0.66, 0.63, 0.60]);
    });

    test('mail scores high on everything, so zero is the wrong anchor', () {
      // The bug this file exists for. A text query scores every email somewhat
      // highly because both sides are text: on the chunked archive the median
      // email scores 0.375 against "white dog" where the median photo scores
      // 0.205. Anchored at zero, `0.75 * best` is selective for photographs
      // and barely above ordinary for mail — searching "white dog" kept 31
      // emails, one about dogs and the rest "Today is the day!", "Happy 4/20!"
      // and a run of word-trivia newsletters.
      //
      // Scores are the real ones measured for "white dog" against the chunked
      // corpus: "dogs", "Fw: SMART DOG!!!", "Separation Anxiety in Dogs", then
      // a puppy-adoption forward, then the first of the word-trivia at 0.549.
      final mail = corpus(
        matches: [0.647, 0.594, 0.585, 0.556, 0.549],
        background: 0.375,
        type: SearchResultType.email,
      );

      final zeroAnchored = 0.647 * VectorRetriever.similarityFloorRatio;
      expect(
        mail.where((h) => h.similarity >= zeroAnchored),
        hasLength(greaterThan(1)),
        reason: 'anchoring at zero really does admit the trivia',
      );

      // Recentred on the background, the dogs survive and the trivia does not.
      expect(VectorRetriever.floorAndCap(mail, 2000).map((h) => h.similarity), [
        0.647,
        0.594,
        0.585,
      ]);
    });

    test('mail is floored lower than photos on an identical distribution', () {
      // Not a preference — a correction for a bias that is measurable and one
      // sided. Mode B ranks mail by fetching the best 10,000 chunk rows out of
      // 30,791, so the median it reads is the median of the top third, not of
      // the corpus. Measured across ten probe queries the true corpus median
      // sits 0.11-0.29 spread-units *below* the one the floor actually uses,
      // which pushes the floor up and prunes mail that should have survived.
      // Photos are not affected: ~4,700 file vectors against the same fetch is
      // full coverage, so their median is the real one and 0.75 still holds.
      //
      // Feeding both types the same numbers is the point. Any difference in
      // what survives comes from the ratio and nothing else.
      const scores = [0.72, 0.68, 0.655, 0.64, 0.60];
      final mail = VectorRetriever.floorAndCap(
        corpus(
          matches: scores,
          background: 0.45,
          type: SearchResultType.email,
        ),
        2000,
      );
      final photos = VectorRetriever.floorAndCap(
        corpus(matches: scores, background: 0.45),
        2000,
      );

      expect(mail.length, greaterThan(photos.length));
    });

    test('the further the best hit stands out, the less survives', () {
      // What the floor can promise, stated as the property it actually has.
      //
      // It cannot promise a modality contributes *nothing*: the floor is
      // derived from that modality's own best hit, so something always
      // survives. That is not a gap to be closed by a cleverer statistic —
      // measured across six queries, (top - median) / (p90 - median) for mail
      // ranged 2.33 to 4.76 and was *highest* for the queries where mail was
      // least relevant, so "this modality has no signal" is not detectable
      // from the distribution. It is also less of a problem than it sounds:
      // in a 1,279-email archive the best match is nearly always at least
      // loosely on topic, and searching "white dog" leaves exactly one email,
      // about dogs.
      final decisive = VectorRetriever.floorAndCap(
        corpus(matches: [0.68, 0.40, 0.38], background: 0.205),
        2000,
      );
      final murky = VectorRetriever.floorAndCap(
        corpus(matches: [0.40, 0.38, 0.36], background: 0.205),
        2000,
      );

      expect(decisive, hasLength(1));
      expect(murky.length, greaterThan(decisive.length));
    });

    test('photos are judged against their own, lower background', () {
      // The same call on the same query must not measure photographs against
      // mail's scale. Cross-modal similarity tops out near 0.36 here — below
      // the 0.433 that mail's own floor sits at — so a shared floor would
      // erase every photograph and leave a search for family pictures as pure
      // mail. Each caller passes one SearchResultType, which is what prevents
      // it.
      final photos = corpus(matches: [0.36, 0.33], background: 0.205);
      expect(VectorRetriever.floorAndCap(photos, 2000), isNotEmpty);
    });

    test('keeps everything when the whole result set is strong', () {
      // 1,200 real photos of the same dog must not be truncated to a fixed N.
      // Measured: `snow mountains` clears the floor on 481 photos and every
      // one is on topic, where the old cap of 300 silently discarded 181.
      final matches = List<double>.generate(1200, (i) => 0.68 - i * 0.00005);
      final kept = VectorRetriever.floorAndCap(
        corpus(matches: matches, background: 0.205, backgroundCount: 1200),
        2000,
      );
      expect(kept, hasLength(1200));
    });

    test('the ceiling still bounds a pathological result set', () {
      // 5,000 genuinely strong hits over a background broad enough that the
      // median lands in it — otherwise the matches calibrate against
      // themselves and the floor rises to meet them.
      final matches = List<double>.generate(5000, (i) => 0.68 - i * 0.00001);
      final kept = VectorRetriever.floorAndCap(
        corpus(matches: matches, background: 0.205, backgroundCount: 6000),
        2000,
      );
      expect(kept, hasLength(2000));
    });

    test('adapts to a query that scores low across the board', () {
      // A vaguer query compresses every score. An absolute floor tuned on the
      // 0.51 that "white dog" needed would return nothing here; measuring the
      // gap between background and best keeps the separation visible.
      final kept = VectorRetriever.floorAndCap(
        corpus(matches: [0.30, 0.28], background: 0.12),
        2000,
      );
      expect(kept.map((h) => h.similarity), [0.30, 0.28]);
    });

    test('a corpus that points away from the query still returns its best', () {
      // Every score negative. Recentring on the median keeps the comparison
      // the right way round — anchoring on `best * ratio` would not, since
      // 0.75 of a negative number is larger than the number.
      final kept = VectorRetriever.floorAndCap(
        corpus(matches: [-0.02, -0.10], background: -0.30),
        2000,
      );
      expect(kept.first.similarity, -0.02);
    });

    test('no hits stays no hits', () {
      expect(VectorRetriever.floorAndCap(const [], 2000), isEmpty);
    });
  });
}
