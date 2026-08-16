/// Bisecting spherical k-means over Qwen3-VL image embeddings.
///
/// Pure Dart over [Float32List] — no plugins, no database, no Flutter binding —
/// so it can run unchanged inside a clustering isolate or a `dart run` harness.
///
/// Two choices here are load-bearing and worth stating up front:
///
/// **Spherical, not Euclidean.** Qwen3-VL is trained under cosine similarity,
/// and the rest of the app already assumes unit vectors — `findSimilarImages`
/// converts distance to a percentage with `(1 - d/2) * 100`, which is only a
/// similarity if `|x| = 1`. So rows are L2-normalised and every comparison is a
/// dot product. On unit vectors squared Euclidean distance is `2 - 2·cos`, so
/// this is a monotone re-parameterisation of ordinary k-means, not a different
/// objective — it just avoids letting vector magnitude, which carries no
/// meaning here, pull centroids around.
///
/// **Bisecting, not flat.** The photos UI exposes a "number of groups" slider.
/// Running flat k-means per slider position would re-solve from scratch at
/// every notch, and adjacent k are independent solutions — k=12 and k=13 can
/// disagree about almost every assignment, so photos would visibly scatter as
/// the user drags. Splitting one cluster at a time instead produces an ordered
/// sequence of binary splits; replaying the first k-1 of them yields k groups.
/// Consecutive k then differ by exactly one split, groups are nested, and a
/// label computed for a node stays valid at every k where that node is a leaf.
library;

import 'dart:math';
import 'dart:typed_data';

/// One cluster: a node in the bisecting tree.
///
/// Interior nodes keep their members, so a node is a valid group at any k where
/// it is a leaf — that is what lets labels be cached per node rather than per
/// (k, group) pair.
class ClusterNode {
  ClusterNode({
    required this.id,
    required this.parentId,
    required this.members,
    required this.centroid,
    required this.inertia,
  });

  final int id;
  final int? parentId;

  /// Row indices into the dataset this tree was built from.
  final Int32List members;

  /// Unit-length mean direction of [members].
  final Float32List centroid;

  /// Sum over members of `1 - cos(member, centroid)`. Zero when every member is
  /// identical; grows with both spread and member count, so it doubles as the
  /// "which cluster is least coherent" score that drives split order.
  final double inertia;

  int? leftId;
  int? rightId;

  bool get isSplit => leftId != null;
  int get size => members.length;

  /// Mean cosine similarity of a member to the centroid — [inertia] normalised
  /// by size, so clusters of different sizes can be compared for tightness.
  double get coherence => members.isEmpty ? 1.0 : 1.0 - inertia / members.length;
}

/// The full split hierarchy. Build once; [leavesAt] is what the slider calls.
class ClusterTree {
  ClusterTree({
    required this.nodes,
    required this.splitOrder,
    required this.dim,
  });

  final List<ClusterNode> nodes;

  /// Ids of the nodes that were split, in the order they were split. Replaying
  /// a prefix of this list reconstructs any k.
  final List<int> splitOrder;

  final int dim;

  /// Largest number of groups this tree can produce.
  int get maxGroups => splitOrder.length + 1;

  /// The k groups obtained by replaying the first `k - 1` splits, largest
  /// first. Pure tree walk — no distance computation, so it is safe to call
  /// on every slider frame.
  List<ClusterNode> leavesAt(int k) {
    final target = k.clamp(1, maxGroups);
    final leaves = <int>{0};
    for (var i = 0; i < target - 1; i++) {
      final node = nodes[splitOrder[i]];
      leaves.remove(node.id);
      leaves.add(node.leftId!);
      leaves.add(node.rightId!);
    }
    final result = [for (final id in leaves) nodes[id]];
    result.sort((a, b) => b.size.compareTo(a.size));
    return result;
  }

  /// The [count] members of [node] closest to its centroid — the photos to send
  /// a vision model when asking for a group label. Most-central first.
  ///
  /// Deliberately not a random sample: a label is only as good as the images
  /// backing it, and centroid-adjacent members are the ones the label is
  /// actually about. Outliers in a loose cluster would drag it off-topic.
  List<int> representatives(
    ClusterNode node,
    Float32List data, {
    int count = 9,
  }) {
    final scored = <({int index, double similarity})>[];
    for (final index in node.members) {
      scored.add((
        index: index,
        similarity: _dot(data, index * dim, node.centroid, dim),
      ));
    }
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    return [for (final s in scored.take(count)) s.index];
  }
}

/// Scales every row of [data] to unit length, in place.
///
/// Zero-length rows are left alone rather than divided by zero; they sit at the
/// origin and will attach to whichever cluster is examined first, which is the
/// correct handling for a vector that carries no direction.
void l2NormalizeRows(Float32List data, int dim) {
  final rows = data.length ~/ dim;
  for (var row = 0; row < rows; row++) {
    final offset = row * dim;
    var sumSquares = 0.0;
    for (var j = 0; j < dim; j++) {
      final v = data[offset + j];
      sumSquares += v * v;
    }
    if (sumSquares <= 0) continue;
    final inv = 1.0 / sqrt(sumSquares);
    for (var j = 0; j < dim; j++) {
      data[offset + j] *= inv;
    }
  }
}

/// Builds the split hierarchy for [data] (`rows * dim`, row-major, unit rows).
///
/// [maxGroups] caps the slider's upper end. [seed] makes the result
/// reproducible: the same library must produce the same groups across runs, or
/// cached labels would be attached to clusters that no longer mean the same
/// thing.
ClusterTree buildClusterTree(
  Float32List data,
  int dim, {
  required int maxGroups,
  int seed = 0x5EED,
  int restarts = 4,
  int maxIterations = 40,
  void Function(int leaves, int target)? onProgress,
}) {
  final rows = data.length ~/ dim;
  if (rows == 0) {
    throw ArgumentError('cannot cluster an empty dataset');
  }
  // Integer division would otherwise swallow a trailing partial row, and the
  // vector that went missing is the one nobody would think to look for.
  if (data.length % dim != 0) {
    throw ArgumentError(
      'data length ${data.length} is not a whole number of $dim-wide rows',
    );
  }

  final rng = Random(seed);
  final allRows = Int32List(rows);
  for (var i = 0; i < rows; i++) {
    allRows[i] = i;
  }

  final nodes = <ClusterNode>[_makeNode(0, null, allRows, data, dim)];
  final splitOrder = <int>[];

  // Unsplit leaves that still have something to split. Kept as a plain list and
  // scanned linearly: maxGroups is a slider bound in the tens, so a heap would
  // be more machinery than the scan costs.
  final candidates = <int>[0];

  while (nodes.length - splitOrder.length < maxGroups) {
    var bestSlot = -1;
    var bestInertia = 0.0;
    for (var i = 0; i < candidates.length; i++) {
      final node = nodes[candidates[i]];
      if (node.size < 2) continue;
      if (node.inertia > bestInertia) {
        bestInertia = node.inertia;
        bestSlot = i;
      }
    }
    // Every remaining leaf is a singleton or perfectly coherent: there is no
    // split left that would tell the user anything new.
    if (bestSlot < 0) break;

    final parent = nodes[candidates.removeAt(bestSlot)];
    final halves = _bisect(data, dim, parent.members, rng, restarts, maxIterations);
    if (halves == null) continue;

    final left = _makeNode(nodes.length, parent.id, halves.$1, data, dim);
    nodes.add(left);
    final right = _makeNode(nodes.length, parent.id, halves.$2, data, dim);
    nodes.add(right);

    parent.leftId = left.id;
    parent.rightId = right.id;
    splitOrder.add(parent.id);
    candidates..add(left.id)..add(right.id);

    onProgress?.call(splitOrder.length + 1, maxGroups);
  }

  return ClusterTree(nodes: nodes, splitOrder: splitOrder, dim: dim);
}

/// Splits [members] in two with spherical 2-means, best of [restarts] runs.
///
/// Returns null when no run produced two non-empty halves — a set of identical
/// vectors, which cannot be meaningfully divided.
(Int32List, Int32List)? _bisect(
  Float32List data,
  int dim,
  Int32List members,
  Random rng,
  int restarts,
  int maxIterations,
) {
  (Int32List, Int32List)? best;
  var bestInertia = double.infinity;

  for (var attempt = 0; attempt < restarts; attempt++) {
    var centroids = _seedTwoCentroids(data, dim, members, rng);
    final assignment = Uint8List(members.length);

    for (var iteration = 0; iteration < maxIterations; iteration++) {
      var changed = false;
      for (var i = 0; i < members.length; i++) {
        final offset = members[i] * dim;
        final side = _dot(data, offset, centroids.$1, dim) >=
                _dot(data, offset, centroids.$2, dim)
            ? 0
            : 1;
        if (assignment[i] != side) {
          assignment[i] = side;
          changed = true;
        }
      }
      if (!changed && iteration > 0) break;

      final sums = [Float64List(dim), Float64List(dim)];
      final counts = [0, 0];
      for (var i = 0; i < members.length; i++) {
        final side = assignment[i];
        final offset = members[i] * dim;
        final sum = sums[side];
        for (var j = 0; j < dim; j++) {
          sum[j] += data[offset + j];
        }
        counts[side]++;
      }
      // An emptied side means the seeds collapsed onto one another. Restarting
      // the whole attempt is cleaner than re-seeding mid-flight, and with
      // k-means++ seeding it is rare enough not to matter.
      if (counts[0] == 0 || counts[1] == 0) break;

      centroids = (_normalized(sums[0], dim), _normalized(sums[1], dim));
    }

    final leftCount = assignment.where((s) => s == 0).length;
    if (leftCount == 0 || leftCount == members.length) continue;

    final left = Int32List(leftCount);
    final right = Int32List(members.length - leftCount);
    var li = 0;
    var ri = 0;
    for (var i = 0; i < members.length; i++) {
      if (assignment[i] == 0) {
        left[li++] = members[i];
      } else {
        right[ri++] = members[i];
      }
    }

    final inertia = _inertia(data, dim, left) + _inertia(data, dim, right);
    if (inertia < bestInertia) {
      bestInertia = inertia;
      best = (left, right);
    }
  }

  return best;
}

/// k-means++ seeding for two centroids: one member at random, then a second
/// drawn with probability proportional to squared distance from the first.
///
/// On unit vectors squared distance is `2 - 2·cos`, so the far-from-the-first
/// weighting is computed directly from dot products.
(Float32List, Float32List) _seedTwoCentroids(
  Float32List data,
  int dim,
  Int32List members,
  Random rng,
) {
  final first = members[rng.nextInt(members.length)];
  final firstVec = _row(data, first, dim);

  var total = 0.0;
  final weights = Float64List(members.length);
  for (var i = 0; i < members.length; i++) {
    final d2 = 2.0 - 2.0 * _dot(data, members[i] * dim, firstVec, dim);
    final w = d2 > 0 ? d2 : 0.0;
    weights[i] = w;
    total += w;
  }

  if (total <= 0) {
    // Every member is identical to the seed; any second pick is as good as any
    // other, and _bisect will discard the degenerate result.
    return (firstVec, _row(data, members[rng.nextInt(members.length)], dim));
  }

  var target = rng.nextDouble() * total;
  var second = members[members.length - 1];
  for (var i = 0; i < members.length; i++) {
    target -= weights[i];
    if (target <= 0) {
      second = members[i];
      break;
    }
  }
  return (firstVec, _row(data, second, dim));
}

ClusterNode _makeNode(
  int id,
  int? parentId,
  Int32List members,
  Float32List data,
  int dim,
) {
  final sum = Float64List(dim);
  for (final index in members) {
    final offset = index * dim;
    for (var j = 0; j < dim; j++) {
      sum[j] += data[offset + j];
    }
  }
  final centroid = _normalized(sum, dim);
  return ClusterNode(
    id: id,
    parentId: parentId,
    members: members,
    centroid: centroid,
    inertia: _inertiaAgainst(data, dim, members, centroid),
  );
}

/// Inertia of [members] about their own mean direction.
///
/// Uses the identity that for a centroid `c = sum/|sum|`, the summed cosine to
/// c is `dot(sum, c) = |sum|` — so the whole cluster's inertia falls out of the
/// sum vector's magnitude without a second pass over the members.
double _inertia(Float32List data, int dim, Int32List members) {
  final sum = Float64List(dim);
  for (final index in members) {
    final offset = index * dim;
    for (var j = 0; j < dim; j++) {
      sum[j] += data[offset + j];
    }
  }
  var magnitude = 0.0;
  for (var j = 0; j < dim; j++) {
    magnitude += sum[j] * sum[j];
  }
  return members.length - sqrt(magnitude);
}

double _inertiaAgainst(
  Float32List data,
  int dim,
  Int32List members,
  Float32List centroid,
) {
  var total = 0.0;
  for (final index in members) {
    total += 1.0 - _dot(data, index * dim, centroid, dim);
  }
  return total;
}

Float32List _normalized(Float64List sum, int dim) {
  var magnitude = 0.0;
  for (var j = 0; j < dim; j++) {
    magnitude += sum[j] * sum[j];
  }
  final out = Float32List(dim);
  if (magnitude <= 0) return out;
  final inv = 1.0 / sqrt(magnitude);
  for (var j = 0; j < dim; j++) {
    out[j] = sum[j] * inv;
  }
  return out;
}

Float32List _row(Float32List data, int index, int dim) =>
    Float32List.sublistView(data, index * dim, (index + 1) * dim);

double _dot(Float32List data, int offset, Float32List other, int dim) {
  var total = 0.0;
  for (var j = 0; j < dim; j++) {
    total += data[offset + j] * other[j];
  }
  return total;
}
