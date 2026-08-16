import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/services/rank_fusion.dart';

void main() {
  group('RankFusion.fuse', () {
    test('empty input produces no results', () {
      expect(RankFusion.fuse({}), isEmpty);
    });

    test('a retriever with an empty list contributes nothing', () {
      expect(RankFusion.fuse({'lexical': []}), isEmpty);
    });

    test('single list scores match the RRF formula at 1-based rank', () {
      final fused = RankFusion.fuse({
        'lexical': ['a', 'b', 'c'],
      });

      // score = weight / (k + rank), rank is 1-based: top result is 1/61,
      // not 1/60 — this is the exact off-by-one the implementation comment
      // warns about, so it's worth pinning to hand-computed numbers rather
      // than just asserting descending order.
      expect(fused.map((f) => f.id).toList(), ['a', 'b', 'c']);
      expect(fused[0].score, closeTo(1 / 61, 1e-12));
      expect(fused[1].score, closeTo(1 / 62, 1e-12));
      expect(fused[2].score, closeTo(1 / 63, 1e-12));

      // 0-based in the public ranks map, per the documented contract.
      expect(fused[0].ranks, {'lexical': 0});
      expect(fused[2].ranks, {'lexical': 2});
    });

    test('weights multiply each retriever\'s contribution', () {
      final fused = RankFusion.fuse(
        {
          'lexical': ['a', 'b'],
          'vector': ['b', 'a'],
        },
        weights: {'lexical': 2.0, 'vector': 1.0},
      );

      final byId = {for (final f in fused) f.id: f.score};
      final expectedA = 2.0 / 61 + 1.0 / 62; // lexical rank1, vector rank2
      final expectedB = 2.0 / 62 + 1.0 / 61; // lexical rank2, vector rank1

      expect(byId['a'], closeTo(expectedA, 1e-12));
      expect(byId['b'], closeTo(expectedB, 1e-12));
      // a's higher-weighted retriever placed it first, so despite b also
      // being found at the same pair of ranks (just swapped), a should win.
      expect(fused.first.id, 'a');
    });

    test('a retriever absent from weights defaults to 1.0', () {
      final withDefault = RankFusion.fuse({
        'r1': ['a'],
      });
      final withExplicit = RankFusion.fuse(
        {
          'r1': ['a'],
        },
        weights: {'r1': 1.0},
      );

      expect(withDefault.single.score, withExplicit.single.score);
    });

    test('a weight of 0.0 zeroes the score but the rank is still recorded', () {
      final fused = RankFusion.fuse(
        {
          'r1': ['a'],
        },
        weights: {'r1': 0.0},
      );

      expect(fused.single.score, 0.0);
      expect(fused.single.ranks, {'r1': 0});
    });

    test('equal scores are broken deterministically by id', () {
      // Both ids get identical treatment (rank 0 in a single-entry list) but
      // from different retrievers, so their scores tie exactly.
      final fused = RankFusion.fuse({
        'r1': ['b'],
        'r2': ['a'],
      });

      expect(fused[0].score, fused[1].score);
      expect(fused.map((f) => f.id).toList(), ['a', 'b']);
    });

    test('repeated fusion of the same input always returns the same order', () {
      final input = {
        'r1': ['x', 'y', 'z'],
        'r2': ['y', 'z', 'x'],
      };

      final first = RankFusion.fuse(input).map((f) => f.id).toList();
      for (var i = 0; i < 5; i++) {
        expect(RankFusion.fuse(input).map((f) => f.id).toList(), first);
      }
    });

    test('a duplicate id within one list keeps its first (best) rank', () {
      final fused = RankFusion.fuse({
        'r1': ['a', 'b', 'a'],
      });

      // Only two distinct ids should appear, and 'a' must have been scored
      // once, at rank 0 — not overwritten by its later occurrence at rank 2.
      expect(fused.length, 2);
      final a = fused.firstWhere((f) => f.id == 'a');
      expect(a.ranks, {'r1': 0});
      expect(a.score, closeTo(1 / 61, 1e-12));
    });

    test(
      'two retrievers agreeing outranks one retriever\'s single best pick',
      () {
        // x: only r1 found it, at its very best rank.
        // y: r1 found it one place worse, but r2 also found it at its best
        // rank. RRF's whole premise is that corroboration beats a single
        // strong opinion — if this fails, the implementation degenerated into
        // "best single rank wins", which isn't RRF.
        final fused = RankFusion.fuse({
          'r1': ['x', 'y'],
          'r2': ['y'],
        });

        final x = fused.firstWhere((f) => f.id == 'x');
        final y = fused.firstWhere((f) => f.id == 'y');

        expect(x.score, closeTo(1 / 61, 1e-12));
        expect(y.score, closeTo(1 / 62 + 1 / 61, 1e-12));
        expect(y.score, greaterThan(x.score));
        expect(fused.first.id, 'y');
      },
    );

    test('a custom k changes the formula\'s denominator', () {
      final fused = RankFusion.fuse({
        'r1': ['a'],
      }, k: 0);

      expect(fused.single.score, closeTo(1 / 1, 1e-12));
    });
  });
}
