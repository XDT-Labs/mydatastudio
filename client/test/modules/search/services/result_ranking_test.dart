import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/services/result_ranking.dart';

void main() {
  group('ResultRanking.tierMultiplier', () {
    test('curatedByUser is the strongest boost', () {
      expect(
        ResultRanking.tierMultiplier(SourceTier.curatedByUser),
        closeTo(1.5, 1e-9),
      );
    });

    test('personalArchive', () {
      expect(
        ResultRanking.tierMultiplier(SourceTier.personalArchive),
        closeTo(1.2, 1e-9),
      );
    });

    test('correspondence is the neutral baseline', () {
      expect(
        ResultRanking.tierMultiplier(SourceTier.correspondence),
        closeTo(1.0, 1e-9),
      );
    });

    test('receivedAttachment is discounted, not someone else\'s artifact', () {
      expect(
        ResultRanking.tierMultiplier(SourceTier.receivedAttachment),
        closeTo(0.8, 1e-9),
      );
    });
  });

  group('ResultRanking.recencyMultiplier', () {
    test('a same-day item is not discounted at all', () {
      final now = DateTime(2026, 1, 1);
      expect(
        ResultRanking.recencyMultiplier(now, now: now),
        closeTo(1.0, 1e-9),
      );
    });

    test(
      'a moderately recent item decays below 1.0 but stays off the floor',
      () {
        final now = DateTime(2026, 1, 31);
        final date = DateTime(2026, 1, 1); // 30 days old
        expect(
          ResultRanking.recencyMultiplier(date, now: now),
          closeTo(0.926794, 1e-6),
        );
      },
    );

    test('the floor engages for a very old item instead of letting the '
        'unclamped curve (~0.26 for 17 years) dominate the fused score', () {
      final now = DateTime(2026, 1, 1);
      final date = DateTime(2009, 1, 1); // 17 years old
      expect(
        ResultRanking.recencyMultiplier(date, now: now),
        closeTo(0.75, 1e-9),
      );
    });

    test('null date is unknown age, not old age, so it is not punished', () {
      final now = DateTime(2026, 1, 1);
      expect(
        ResultRanking.recencyMultiplier(null, now: now),
        closeTo(1.0, 1e-9),
      );
    });

    test('a future date (clock skew, bad EXIF) does not score above '
        'everything else', () {
      final now = DateTime(2026, 1, 1);
      final date = DateTime(2027, 1, 1);
      expect(
        ResultRanking.recencyMultiplier(date, now: now),
        closeTo(1.0, 1e-9),
      );
    });
  });

  group('ResultRanking.adjust', () {
    test('composes the tier boost and the recency decay multiplicatively', () {
      final now = DateTime(2026, 1, 31);
      final date = DateTime(2026, 1, 1); // 30 days old
      expect(
        ResultRanking.adjust(
          100.0,
          tier: SourceTier.personalArchive,
          date: date,
          now: now,
        ),
        closeTo(111.215282, 1e-4),
      );
    });
  });
}
