import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/clustering/spherical_kmeans.dart';

/// Builds `groups * perGroup` unit vectors in [dim] dimensions, where each
/// group is a tight cone around its own axis. Separation is unambiguous, so any
/// correct clustering must recover exactly these groups.
Float32List _syntheticBlobs({
  required int groups,
  required int perGroup,
  required int dim,
  double jitter = 0.05,
  int seed = 7,
}) {
  final rng = Random(seed);
  final data = Float32List(groups * perGroup * dim);
  var row = 0;
  for (var g = 0; g < groups; g++) {
    for (var i = 0; i < perGroup; i++) {
      final offset = row * dim;
      for (var d = 0; d < dim; d++) {
        data[offset + d] = (rng.nextDouble() - 0.5) * jitter;
      }
      // Dominant coordinate identifies the group; jitter never overcomes it.
      data[offset + g] = 1.0;
      row++;
    }
  }
  l2NormalizeRows(data, dim);
  return data;
}

void main() {
  group('l2NormalizeRows', () {
    test('scales every row to unit length', () {
      final data = Float32List.fromList([3, 4, 0, 0, 0, 5]);
      l2NormalizeRows(data, 3);
      expect(data[0], closeTo(0.6, 1e-6));
      expect(data[1], closeTo(0.8, 1e-6));
      expect(data[5], closeTo(1.0, 1e-6));
    });

    test('leaves a zero row alone instead of dividing by zero', () {
      final data = Float32List.fromList([0, 0, 0, 1, 0, 0]);
      l2NormalizeRows(data, 3);
      expect(data.sublist(0, 3), everyElement(0.0));
      expect(data[3], closeTo(1.0, 1e-6));
    });
  });

  group('buildClusterTree', () {
    test('recovers well-separated groups', () {
      const groups = 6;
      const perGroup = 25;
      const dim = 16;
      final data = _syntheticBlobs(groups: groups, perGroup: perGroup, dim: dim);

      final tree = buildClusterTree(data, dim, maxGroups: groups);
      final leaves = tree.leavesAt(groups);

      expect(leaves, hasLength(groups));
      // Each recovered group must be exactly one synthetic blob — members of a
      // blob occupy a contiguous index range, so a pure leaf has one distinct
      // `index ~/ perGroup` value.
      for (final leaf in leaves) {
        final origins = leaf.members.map((i) => i ~/ perGroup).toSet();
        expect(origins, hasLength(1), reason: 'leaf ${leaf.id} mixes blobs');
        expect(leaf.size, perGroup);
      }
    });

    test('every k partitions the dataset exactly once', () {
      const rows = 120;
      const dim = 12;
      final data = _syntheticBlobs(groups: 8, perGroup: 15, dim: dim);
      final tree = buildClusterTree(data, dim, maxGroups: 20);

      for (var k = 1; k <= tree.maxGroups; k++) {
        final leaves = tree.leavesAt(k);
        expect(leaves, hasLength(k), reason: 'wrong group count at k=$k');
        final seen = <int>{};
        for (final leaf in leaves) {
          for (final index in leaf.members) {
            expect(seen.add(index), isTrue,
                reason: 'row $index appears in two groups at k=$k');
          }
        }
        expect(seen, hasLength(rows), reason: 'rows missing at k=$k');
      }
    });

    // The reason this is bisecting k-means and not flat k-means. The UI slider
    // is only usable if one notch changes one group: with flat k-means, k and
    // k+1 are independent solves and photos scatter across the whole grid.
    test('groups are nested — k+1 refines k, never reshuffles it', () {
      const dim = 12;
      final data = _syntheticBlobs(groups: 8, perGroup: 15, dim: dim);
      final tree = buildClusterTree(data, dim, maxGroups: 20);

      for (var k = 1; k < tree.maxGroups; k++) {
        final coarse = tree.leavesAt(k);
        final fine = tree.leavesAt(k + 1);

        // Exactly one coarse group is absent from the finer cut: the one split.
        final coarseIds = {for (final n in coarse) n.id};
        final fineIds = {for (final n in fine) n.id};
        expect(coarseIds.difference(fineIds), hasLength(1),
            reason: 'more than one group changed between k=$k and k=${k + 1}');

        // Every finer group sits wholly inside one coarser group.
        for (final leaf in fine) {
          final members = leaf.members.toSet();
          final container = coarse.where(
            (c) => members.every(c.members.contains),
          );
          expect(container, isNotEmpty,
              reason: 'group ${leaf.id} at k=${k + 1} straddles two groups at k=$k');
        }
      }
    });

    test('is deterministic for a given seed', () {
      const dim = 12;
      final a = buildClusterTree(
        _syntheticBlobs(groups: 5, perGroup: 20, dim: dim),
        dim,
        maxGroups: 12,
        seed: 99,
      );
      final b = buildClusterTree(
        _syntheticBlobs(groups: 5, perGroup: 20, dim: dim),
        dim,
        maxGroups: 12,
        seed: 99,
      );

      expect(b.splitOrder, a.splitOrder);
      for (var k = 1; k <= a.maxGroups; k++) {
        expect(
          [for (final n in b.leavesAt(k)) n.members.toList()],
          [for (final n in a.leavesAt(k)) n.members.toList()],
          reason: 'cluster membership differs at k=$k',
        );
      }
    });

    test('stops splitting when members are identical', () {
      const dim = 8;
      // 30 copies of one direction: there is no meaningful split to make, so
      // the tree must refuse to invent one rather than emit empty groups.
      final data = Float32List(30 * dim);
      for (var row = 0; row < 30; row++) {
        data[row * dim] = 1.0;
      }
      final tree = buildClusterTree(data, dim, maxGroups: 10);

      expect(tree.maxGroups, 1);
      expect(tree.leavesAt(10), hasLength(1));
      expect(tree.leavesAt(10).single.size, 30);
    });

    test('representatives are ordered by closeness to the centroid', () {
      const dim = 16;
      final data = _syntheticBlobs(groups: 4, perGroup: 20, dim: dim);
      final tree = buildClusterTree(data, dim, maxGroups: 4);
      final node = tree.leavesAt(4).first;

      final reps = tree.representatives(node, data, count: 5);
      expect(reps, hasLength(5));
      expect(reps.toSet().length, 5, reason: 'representatives must be distinct');
      expect(node.members, containsAll(reps));

      var previous = double.infinity;
      for (final index in reps) {
        var similarity = 0.0;
        for (var d = 0; d < dim; d++) {
          similarity += data[index * dim + d] * node.centroid[d];
        }
        expect(similarity, lessThanOrEqualTo(previous + 1e-6));
        previous = similarity;
      }
    });

    test('rejects an empty dataset instead of returning a bogus tree', () {
      expect(
        () => buildClusterTree(Float32List(0), 8, maxGroups: 4),
        throwsArgumentError,
      );
    });
  });
}
