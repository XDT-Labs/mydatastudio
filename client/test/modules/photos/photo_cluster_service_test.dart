import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_service.dart';

/// Builds a tree shaped like the bisecting algorithm produces one:
///
///     0 ─┬─ 1 ─┬─ 3
///        │     └─ 4
///        └─ 2
///
/// Split order is [0, 1], so k=1 is {0}, k=2 is {1, 2}, k=3 is {3, 4, 2}.
PhotoClusterTree _tree({Map<int, String>? labels, Map<int, double>? coherence}) {
  ClusterGroup node(int id, int? parent, int? rank, int count) => ClusterGroup(
        runId: 'run-1',
        nodeId: id,
        parentId: parent,
        splitRank: rank,
        memberCount: count,
        coherence: coherence?[id] ?? 0.8,
        centroid: Float32List(4),
        label: labels?[id],
        labelStatus: labels?[id] != null
            ? ClusterLabelStatus.ready
            : ClusterLabelStatus.pending,
      );

  return PhotoClusterTree(
    ClusterRun(
      id: 'run-1',
      scope: const ClusterScope.all(),
      createdAt: DateTime(2026, 1, 1),
      photoCount: 6,
      maxGroups: 3,
      seed: 1,
      status: ClusterRunStatus.ready,
    ),
    [
      node(0, null, 0, 6),
      node(1, 0, 1, 4),
      node(2, 0, null, 2),
      node(3, 1, null, 3),
      node(4, 1, null, 1),
    ],
  );
}

File _photo(String id) => File(
      id: id,
      name: '$id.jpg',
      path: '/photos/$id.jpg',
      parent: '/photos',
      dateCreated: DateTime(2026, 1, 1),
      dateLastModified: DateTime(2026, 1, 1),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 1,
      isDeleted: false,
    );

void main() {
  final service = PhotoClusterService.instance;

  void seedState({
    PhotoClusterTree? tree,
    Map<String, int> membership = const {},
    int groupCount = 3,
  }) {
    service.state.add(ClusterViewState(
      tree: tree ?? _tree(),
      membership: membership,
      groupCount: groupCount,
    ));
  }

  tearDown(() => service.state.add(const ClusterViewState()));

  group('PhotoClusterTree cuts', () {
    test('replays splits to produce k groups', () {
      final tree = _tree();
      expect(tree.maxGroups, 3);
      expect(tree.groupsAt(1).map((g) => g.nodeId), [0]);
      expect(tree.groupsAt(2).map((g) => g.nodeId).toSet(), {1, 2});
      expect(tree.groupsAt(3).map((g) => g.nodeId).toSet(), {3, 4, 2});
    });

    test('groups are ordered largest first', () {
      expect(_tree().groupsAt(3).map((g) => g.memberCount), [3, 2, 1]);
    });

    test('resolves a leaf to its ancestor at each k', () {
      final tree = _tree();
      // A photo stored against leaf 3 belongs to node 0 at k=1, node 1 at k=2,
      // and node 3 at k=3 — the nesting the slider depends on.
      expect(tree.groupIdForLeaf(3, 1), 0);
      expect(tree.groupIdForLeaf(3, 2), 1);
      expect(tree.groupIdForLeaf(3, 3), 3);
    });

    test('clamps a k beyond the tree instead of throwing', () {
      final tree = _tree();
      expect(tree.groupsAt(99).length, 3);
      expect(tree.groupsAt(0).length, 1);
    });
  });

  group('groupPhotos', () {
    test('buckets photos by their group at the current k', () {
      seedState(
        membership: {'a': 3, 'b': 3, 'c': 4, 'd': 2},
        groupCount: 3,
      );

      final groups = service.groupPhotos(
        [_photo('a'), _photo('b'), _photo('c'), _photo('d')],
      );

      expect(groups.map((g) => g.group.nodeId), [3, 2, 4]);
      expect(groups.first.photos.map((p) => p.id), ['a', 'b']);
    });

    test('merges buckets as the slider moves down', () {
      seedState(
        membership: {'a': 3, 'b': 4, 'c': 2},
        groupCount: 2,
      );

      final groups = service.groupPhotos(
        [_photo('a'), _photo('b'), _photo('c')],
      );

      // Leaves 3 and 4 both live under node 1 at k=2, so their photos merge
      // rather than being reshuffled into unrelated groups.
      expect(groups.map((g) => g.group.nodeId), [1, 2]);
      expect(groups.first.photos.map((p) => p.id).toSet(), {'a', 'b'});
    });

    // Photos scanned since the run was built have no membership row. Dropping
    // them is deliberate — a catch-all bucket would claim they had been grouped
    // — so the count has to surface instead.
    test('drops ungrouped photos and reports them as uncovered', () {
      seedState(membership: {'a': 3}, groupCount: 3);

      final photos = [_photo('a'), _photo('new-1'), _photo('new-2')];
      final groups = service.groupPhotos(photos);

      expect(groups, hasLength(1));
      expect(groups.single.photos.map((p) => p.id), ['a']);
      expect(service.uncoveredCount(photos), 2);
    });

    test('omits groups with no photos left after filtering', () {
      seedState(membership: {'a': 3, 'b': 2}, groupCount: 3);

      // Only the photo in leaf 3 survives whatever filter the view applied.
      final groups = service.groupPhotos([_photo('a')]);
      expect(groups.map((g) => g.group.nodeId), [3]);
    });

    test('returns nothing when no run is loaded', () {
      service.state.add(const ClusterViewState());
      expect(service.groupPhotos([_photo('a')]), isEmpty);
      expect(service.uncoveredCount([_photo('a')]), 1);
    });
  });

  group('group presentation', () {
    test('falls back to a stable placeholder until a label arrives', () {
      seedState(membership: {'a': 3}, groupCount: 3);
      final view = service.groupPhotos([_photo('a')]).single;
      expect(view.label, 'Group 3');
      expect(view.group.labelStatus, ClusterLabelStatus.pending);
    });

    test('uses the stored label once it is ready', () {
      seedState(
        tree: _tree(labels: {3: 'Lighthouses'}),
        membership: {'a': 3},
        groupCount: 3,
      );
      final view = service.groupPhotos([_photo('a')]).single;
      expect(view.label, 'Lighthouses');
      expect(view.group.labelStatus, ClusterLabelStatus.ready);
    });

    // A label is a claim about every photo under it. On an incoherent group
    // that claim is wrong for most of them, so the view marks it.
    test('marks low-coherence groups as mixed', () {
      seedState(
        tree: _tree(coherence: {3: 0.42, 2: 0.81}),
        membership: {'a': 3, 'b': 2},
        groupCount: 3,
      );
      final groups = service.groupPhotos([_photo('a'), _photo('b')]);
      expect(groups.firstWhere((g) => g.group.nodeId == 3).isMixed, isTrue);
      expect(groups.firstWhere((g) => g.group.nodeId == 2).isMixed, isFalse);
    });
  });

  group('setGroupCount', () {
    test('clamps to the tree and ignores calls with no run', () {
      seedState(membership: const {}, groupCount: 2);
      service.setGroupCount(99);
      expect(service.state.value.groupCount, 3);
      service.setGroupCount(0);
      expect(service.state.value.groupCount, 1);

      service.state.add(const ClusterViewState(groupCount: 7));
      service.setGroupCount(2);
      expect(service.state.value.groupCount, 7, reason: 'no tree to cut');
    });
  });

  group('ClusterScope.fromFilter', () {
    test('All Photos when no collection is selected', () {
      expect(ClusterScope.fromFilter(const PhotoFilter()).isAll, isTrue);
    });

    test('follows the selected source', () {
      expect(
        ClusterScope.fromFilter(const PhotoFilter(collectionId: 'gmail')).key,
        'gmail',
      );
      expect(
        ClusterScope.fromFilter(
          const PhotoFilter(collectionIds: ['b', 'a']),
        ).key,
        'a,b',
      );
    });

    // Narrowing by album, tag, or search must not start a new run: it selects
    // a subset of a source's photos, and re-clustering per keystroke would mean
    // a fresh tree — and fresh AI labels — every time the query changed.
    test('ignores non-source narrowing', () {
      const filter = PhotoFilter(
        searchQuery: 'beach',
        albumId: 'album-1',
        tag: 'summer',
        onlyFavorites: true,
      );
      expect(ClusterScope.fromFilter(filter).isAll, isTrue);
    });
  });
}
