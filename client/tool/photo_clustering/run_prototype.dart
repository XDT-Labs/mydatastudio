/// Prototype harness: clusters a real library dump and prints what the groups
/// actually contain, so cluster quality can be judged before any UI is built.
///
/// Run `dump_vectors.py` first, then:
///
///     dart run tool/photo_clustering/run_prototype.dart <dump_dir> [--k 8,20,40]
///
/// Deliberately a script, not a test: the interesting output is prose a human
/// reads and judges, and it runs against a live personal library whose contents
/// no assertion could be written against.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mydatastudio/modules/photos/services/clustering/spherical_kmeans.dart';

const int kDim = 2048;

class PhotoMeta {
  PhotoMeta(this.fileId, this.collection, this.scanner, this.name, this.description);
  final String fileId;
  final String collection;
  final String scanner;
  final String name;
  final String description;

  /// What to show for this photo in a cluster listing. Filenames in a real
  /// library are almost all `IMG_1234.heic`, which says nothing about content —
  /// the generated caption is the only human-readable signal.
  String get label => description.isNotEmpty ? description : '($name)';
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/photo_clustering/run_prototype.dart <dump_dir> [--k 8,20,40] [--max-groups 48]',
    );
    exit(64);
  }

  final dumpDir = args.first;
  final ks = _intListArg(args, '--k') ?? [8, 20, 40];
  final maxGroups = _intArg(args, '--max-groups') ?? (ks.reduce(max) + 8);

  final meta = _readMeta(File('$dumpDir/meta.tsv'));
  final data = _readVectors(File('$dumpDir/vectors.f32'));
  final rows = data.length ~/ kDim;

  if (rows != meta.length) {
    stderr.writeln('vector/meta length mismatch: $rows vs ${meta.length}');
    exit(65);
  }

  print('=' * 78);
  print('LIBRARY: $rows photos x $kDim dims  (${_mb(data.lengthInBytes)} MB)');
  print('=' * 78);
  _printSourceBreakdown(meta);

  final normalizeWatch = Stopwatch()..start();
  l2NormalizeRows(data, kDim);
  normalizeWatch.stop();

  final buildWatch = Stopwatch()..start();
  final tree = buildClusterTree(data, kDim, maxGroups: maxGroups);
  buildWatch.stop();

  print('');
  print('TIMING');
  print('  normalize      ${normalizeWatch.elapsedMilliseconds} ms');
  print('  build tree     ${buildWatch.elapsedMilliseconds} ms '
      '(${tree.splitOrder.length} splits, max $maxGroups groups)');
  print('  slider re-cut  ${_timeSliderCuts(tree, ks)} us per k (tree walk only)');

  _reportStability(tree, ks, rows);
  _reportNearDuplicates(tree, data, meta);

  for (final k in ks) {
    _reportClusters(tree, data, meta, k);
  }
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

void _printSourceBreakdown(List<PhotoMeta> meta) {
  final counts = <String, int>{};
  for (final m in meta) {
    counts[m.scanner] = (counts[m.scanner] ?? 0) + 1;
  }
  final entries = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  print('SOURCES');
  for (final e in entries) {
    print('  ${e.value.toString().padLeft(5)}  ${e.key}');
  }
}

/// The claim bisecting k-means is chosen to deliver: moving the slider by one
/// notch should reshuffle almost nothing. Measures the fraction of photos that
/// keep the same groupmates between consecutive k.
void _reportStability(ClusterTree tree, List<int> ks, int rows) {
  print('');
  print('SLIDER STABILITY  (photos whose group is unchanged from k-1 to k)');
  for (final k in ks) {
    if (k < 2) continue;
    final before = _assignments(tree, k - 1, rows);
    final after = _assignments(tree, k, rows);
    var unchanged = 0;
    // Under a bisecting tree exactly one group splits, so every photo outside
    // that group keeps both its members and its node id.
    for (var i = 0; i < before.length; i++) {
      if (before[i] == after[i]) unchanged++;
    }
    final pct = (100.0 * unchanged / before.length).toStringAsFixed(1);
    print('  k=${(k - 1).toString().padLeft(2)} -> ${k.toString().padLeft(2)}   '
        '$pct% stay put');
  }
}

/// Sanity check on the "duplicates group together" idea: how many photos have a
/// near-twin at cosine >= 0.98, the kind of threshold a dedicated duplicate
/// finder would use rather than relying on cluster membership.
///
/// Compares only within the tree's finest leaves. An all-pairs scan is O(n²·d)
/// — billions of operations even on a small library — and restricting to leaves
/// is what a real implementation would do anyway, since a near-twin at 0.98
/// lands in the same leaf except in the rare case of a split straight through a
/// duplicate pair. Treat the count as a floor, not a census.
void _reportNearDuplicates(
  ClusterTree tree,
  Float32List data,
  List<PhotoMeta> meta,
) {
  const threshold = 0.98;
  var pairs = 0;
  final withTwin = <int>{};
  final samples = <String>[];

  for (final node in tree.leavesAt(tree.maxGroups)) {
    final members = node.members;
    for (var a = 0; a < members.length; a++) {
      for (var b = a + 1; b < members.length; b++) {
        final i = members[a];
        final j = members[b];
        var dot = 0.0;
        final oi = i * kDim;
        final oj = j * kDim;
        for (var d = 0; d < kDim; d++) {
          dot += data[oi + d] * data[oj + d];
        }
        if (dot >= threshold) {
          pairs++;
          withTwin..add(i)..add(j);
          if (samples.length < 3) {
            samples.add('${_truncate(meta[i].name, 34)}  <->  '
                '${_truncate(meta[j].name, 34)}   cos ${dot.toStringAsFixed(4)}');
          }
        }
      }
    }
  }

  print('');
  print('NEAR-DUPLICATES  (cosine >= $threshold, within-leaf scan)');
  print('  $pairs pairs across ${withTwin.length} photos');
  for (final s in samples) {
    print('  e.g. $s');
  }
}

void _reportClusters(
  ClusterTree tree,
  Float32List data,
  List<PhotoMeta> meta,
  int k,
) {
  final leaves = tree.leavesAt(k);
  print('');
  print('=' * 78);
  print('k = $k  (${leaves.length} groups)');
  print('=' * 78);

  for (final node in leaves) {
    final scanners = <String, int>{};
    for (final index in node.members) {
      final s = meta[index].scanner;
      scanners[s] = (scanners[s] ?? 0) + 1;
    }
    final dominant = scanners.entries.reduce((a, b) => a.value >= b.value ? a : b);
    final purity = (100.0 * dominant.value / node.size).round();

    print('');
    print('-- node ${node.id}  n=${node.size}  '
        'coherence ${node.coherence.toStringAsFixed(3)}  '
        'source ${dominant.key} $purity%');
    for (final index in tree.representatives(node, data, count: 5)) {
      print('     ${_truncate(meta[index].label, 92)}');
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Group id per photo at [k], indexed by dataset row.
Int32List _assignments(ClusterTree tree, int k, int rows) {
  final out = Int32List(rows);
  for (final node in tree.leavesAt(k)) {
    for (final index in node.members) {
      out[index] = node.id;
    }
  }
  return out;
}

int _timeSliderCuts(ClusterTree tree, List<int> ks) {
  final watch = Stopwatch()..start();
  const reps = 200;
  for (var i = 0; i < reps; i++) {
    for (final k in ks) {
      tree.leavesAt(k);
    }
  }
  watch.stop();
  return watch.elapsedMicroseconds ~/ (reps * ks.length);
}

List<PhotoMeta> _readMeta(File file) {
  final out = <PhotoMeta>[];
  for (final line in file.readAsLinesSync()) {
    if (line.isEmpty) continue;
    final parts = line.split('\t');
    out.add(PhotoMeta(
      parts.elementAtOrNull(0) ?? '',
      parts.elementAtOrNull(1) ?? '',
      parts.elementAtOrNull(2) ?? '',
      parts.elementAtOrNull(3) ?? '',
      parts.elementAtOrNull(4) ?? '',
    ));
  }
  return out;
}

Float32List _readVectors(File file) {
  final bytes = file.readAsBytesSync();
  // Float32List.view needs a 4-byte-aligned offset and readAsBytesSync makes no
  // such guarantee, so fall back to a copying read when it isn't aligned.
  if (bytes.offsetInBytes % 4 == 0) {
    return Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ 4,
    );
  }
  final view = ByteData.sublistView(bytes);
  final out = Float32List(bytes.lengthInBytes ~/ 4);
  for (var i = 0; i < out.length; i++) {
    out[i] = view.getFloat32(i * 4, Endian.little);
  }
  return out;
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

String _truncate(String s, int n) => s.length <= n ? s : '${s.substring(0, n - 1)}…';

int? _intArg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return int.tryParse(args[i + 1]);
}

List<int>? _intListArg(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  final parsed = args[i + 1].split(',').map(int.tryParse).whereType<int>().toList();
  return parsed.isEmpty ? null : (parsed..sort());
}
