/// Persistence-side models for photo clustering.
///
/// Plain Dart with hand-written `fromMap`/`toMap`, matching `models/tables/` —
/// there is no code generation for the schema in this project.
///
/// These are deliberately separate from `spherical_kmeans.dart`, which is the
/// compute side and knows nothing about SQLite. The algorithm works in dataset
/// row indices over one big `Float32List`; what gets stored is file ids and a
/// tree shape. Keeping the two apart is what lets the algorithm run in an
/// isolate, a test, or a `dart run` harness without dragging a database along.
library;

import 'dart:typed_data';

import 'package:mydatastudio/modules/photos/models/photo_filter.dart';

/// How a run's photo set was scoped — the drawer's source filter at the time.
///
/// `null` collection ids mean All Photos. Anything else is the selected
/// collections, and the ids are sorted so that the same selection always
/// produces the same key regardless of the order the UI hands them over.
class ClusterScope {
  const ClusterScope(this.collectionIds);

  const ClusterScope.all() : collectionIds = null;

  final List<String>? collectionIds;

  bool get isAll => collectionIds == null || collectionIds!.isEmpty;

  /// Canonical string stored in `photo_cluster_runs.collection_scope`.
  String? get key {
    if (isAll) return null;
    final sorted = [...collectionIds!]..sort();
    return sorted.join(',');
  }

  static ClusterScope fromKey(String? key) {
    if (key == null || key.isEmpty) return const ClusterScope.all();
    return ClusterScope(key.split(','));
  }

  /// The scope implied by the drawer's current source filter.
  ///
  /// Only the collection selection is carried over. Narrowing by album, tag,
  /// location, favourites or search does not start a new run: those pick a
  /// subset of photos out of a source, and re-clustering per search term would
  /// mean a fresh tree — and a fresh set of AI labels — on every keystroke.
  /// The run stays scoped to the source; the view shows whichever of its
  /// photos survive the rest of the filter.
  factory ClusterScope.fromFilter(PhotoFilter filter) {
    if (filter.collectionIds != null && filter.collectionIds!.isNotEmpty) {
      return ClusterScope(filter.collectionIds!);
    }
    if (filter.collectionId != null) {
      return ClusterScope([filter.collectionId!]);
    }
    return const ClusterScope.all();
  }

  @override
  bool operator ==(Object other) =>
      other is ClusterScope && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

enum ClusterRunStatus { building, ready, stale }

/// One clustering pass over one scope.
class ClusterRun {
  ClusterRun({
    required this.id,
    required this.scope,
    required this.createdAt,
    required this.photoCount,
    required this.maxGroups,
    required this.seed,
    required this.status,
    this.lastGroupCount,
  });

  final String id;
  final ClusterScope scope;
  final DateTime createdAt;
  final int photoCount;
  final int maxGroups;
  final int seed;
  final ClusterRunStatus status;

  /// Where the user last left the group slider for this run's scope, or null if
  /// they have never moved it.
  final int? lastGroupCount;

  factory ClusterRun.fromMap(Map<String, Object?> map) => ClusterRun(
        id: map['id'] as String,
        scope: ClusterScope.fromKey(map['collection_scope'] as String?),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          map['created_at'] as int,
        ),
        photoCount: map['photo_count'] as int,
        maxGroups: map['max_groups'] as int,
        seed: map['seed'] as int,
        status: ClusterRunStatus.values.firstWhere(
          (s) => s.name == map['status'],
          orElse: () => ClusterRunStatus.ready,
        ),
        lastGroupCount: map['last_group_count'] as int?,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'collection_scope': scope.key,
        'created_at': createdAt.millisecondsSinceEpoch,
        'photo_count': photoCount,
        'max_groups': maxGroups,
        'seed': seed,
        'status': status.name,
        'last_group_count': lastGroupCount,
      };

  ClusterRun copyWith({ClusterRunStatus? status, int? lastGroupCount}) =>
      ClusterRun(
        id: id,
        scope: scope,
        createdAt: createdAt,
        photoCount: photoCount,
        maxGroups: maxGroups,
        seed: seed,
        status: status ?? this.status,
        lastGroupCount: lastGroupCount ?? this.lastGroupCount,
      );
}

enum ClusterLabelStatus { pending, ready, failed, skipped }

/// One node of a run's split tree.
class ClusterGroup {
  ClusterGroup({
    required this.runId,
    required this.nodeId,
    required this.parentId,
    required this.splitRank,
    required this.memberCount,
    required this.coherence,
    required this.centroid,
    this.representatives = const [],
    this.label,
    this.labelStatus = ClusterLabelStatus.pending,
  });

  final String runId;
  final int nodeId;
  final int? parentId;

  /// Position in the run's split sequence, or null if this node was never
  /// split. Replaying splits `0..k-2` produces the k groups the slider asks
  /// for — see [PhotoClusterTree.groupsAt].
  final int? splitRank;

  final int memberCount;

  /// Mean cosine similarity of members to the centroid. Low values mean the
  /// group is genuinely mixed and a single label will misrepresent it.
  final double coherence;

  final Float32List centroid;

  /// Members nearest the centroid — the photos shown to the vision model when
  /// naming this group. Most-central first.
  ///
  /// Chosen rather than sampled at random because a label is only as good as
  /// the images behind it: centroid-adjacent members are what the group is
  /// actually about, where an outlier in a loose group would drag the name
  /// off-topic.
  final List<String> representatives;

  final String? label;
  final ClusterLabelStatus labelStatus;

  /// What to show before a label arrives. Labels are generated in the
  /// background one group at a time, so the UI needs something stable to
  /// render meanwhile.
  String get displayLabel => label?.isNotEmpty == true ? label! : 'Group $nodeId';

  factory ClusterGroup.fromMap(Map<String, Object?> map) {
    final blob = map['centroid'] as Uint8List;
    return ClusterGroup(
      runId: map['run_id'] as String,
      nodeId: map['node_id'] as int,
      parentId: map['parent_id'] as int?,
      splitRank: map['split_rank'] as int?,
      memberCount: map['member_count'] as int,
      coherence: (map['coherence'] as num).toDouble(),
      // Copy rather than view: the row's buffer is not guaranteed to be
      // 4-byte aligned, and Float32List.view throws on an unaligned offset.
      centroid: Float32List.sublistView(
        Uint8List.fromList(blob),
      ),
      representatives: switch (map['representatives']) {
        final String csv when csv.isNotEmpty => csv.split(','),
        _ => const <String>[],
      },
      label: map['label'] as String?,
      labelStatus: ClusterLabelStatus.values.firstWhere(
        (s) => s.name == map['label_status'],
        orElse: () => ClusterLabelStatus.pending,
      ),
    );
  }

  Map<String, Object?> toMap() => {
        'run_id': runId,
        'node_id': nodeId,
        'parent_id': parentId,
        'split_rank': splitRank,
        'member_count': memberCount,
        'coherence': coherence,
        'centroid': centroid.buffer.asUint8List(
          centroid.offsetInBytes,
          centroid.lengthInBytes,
        ),
        'representatives': representatives.join(','),
        'label': label,
        'label_status': labelStatus.name,
      };
}

/// A run's tree, rehydrated from the database and able to answer "what are the
/// groups at k?" without touching the database again.
///
/// Membership is stored once per photo, against its deepest leaf. The groups at
/// a given k are that leaf's ancestors, so resolving a photo's group is a walk
/// up `parentId` rather than a second membership table per level. The whole
/// tree is at most a couple of hundred nodes, so every operation here is cheap
/// enough to run on a slider drag.
class PhotoClusterTree {
  PhotoClusterTree(this.run, List<ClusterGroup> groups)
      : _byId = {for (final g in groups) g.nodeId: g},
        _splitSequence = (groups.where((g) => g.splitRank != null).toList()
              ..sort((a, b) => a.splitRank!.compareTo(b.splitRank!)))
            .map((g) => g.nodeId)
            .toList();

  final ClusterRun run;
  final Map<int, ClusterGroup> _byId;
  final List<int> _splitSequence;

  Iterable<ClusterGroup> get allGroups => _byId.values;

  ClusterGroup? group(int nodeId) => _byId[nodeId];

  /// Largest number of groups this tree can produce.
  int get maxGroups => _splitSequence.length + 1;

  /// The k groups obtained by replaying the first `k - 1` splits, largest
  /// first. Pure map lookups — safe to call on every slider frame.
  List<ClusterGroup> groupsAt(int k) {
    final target = k.clamp(1, maxGroups);
    final leaves = <int>{_rootId};
    for (var i = 0; i < target - 1; i++) {
      final parent = _splitSequence[i];
      leaves.remove(parent);
      for (final child in _childrenOf(parent)) {
        leaves.add(child);
      }
    }
    final result = [for (final id in leaves) _byId[id]!];
    result.sort((a, b) => b.memberCount.compareTo(a.memberCount));
    return result;
  }

  /// Maps a photo's stored leaf to whichever of the k groups contains it.
  ///
  /// Returns null only if the tree is inconsistent with the membership rows —
  /// a leaf id that isn't in this run.
  int? groupIdForLeaf(int leafNodeId, int k) {
    final groupIds = {for (final g in groupsAt(k)) g.nodeId};
    int? cursor = leafNodeId;
    while (cursor != null) {
      if (groupIds.contains(cursor)) return cursor;
      cursor = _byId[cursor]?.parentId;
    }
    return null;
  }

  int get _rootId {
    for (final g in _byId.values) {
      if (g.parentId == null) return g.nodeId;
    }
    throw StateError('cluster run ${run.id} has no root node');
  }

  List<int> _childrenOf(int nodeId) => [
        for (final g in _byId.values)
          if (g.parentId == nodeId) g.nodeId,
      ];
}
