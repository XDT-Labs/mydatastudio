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
PhotoClusterTree _tree({
  Map<int, String>? labels,
  Map<int, double>? coherence,
  int runMaxGroups = 3,
}) {
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
      maxGroups: runMaxGroups,
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
    test('falls back to a placeholder until a label arrives', () {
      seedState(membership: {'a': 3}, groupCount: 3);
      final view = service.groupPhotos([_photo('a')]).single;
      // Position, not node id — this photo sits in node 3, but it is the only
      // group on screen, so it is "Group 1". See the group numbering tests.
      expect(view.label, 'Group 1');
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

  group('group numbering', () {
    // The bug this replaced: the placeholder counted by nodeId, which indexes
    // the whole split tree (95 nodes for a 48-group run). A view of 48 groups
    // showed headers reading "Group 80" and "Group 94", which read as a count
    // and told the user there were more groups than existed.
    test('placeholder numbers by position, never by node id', () {
      seedState(membership: {'a': 3, 'b': 4, 'c': 2}, groupCount: 3);
      final groups = service.groupPhotos(
        [_photo('a'), _photo('b'), _photo('c')],
      );

      expect(groups.map((g) => g.label), ['Group 1', 'Group 2', 'Group 3']);
      // Node ids are 2, 3 and 4 here — none of them leak into the labels.
      expect(groups.map((g) => g.position), [1, 2, 3]);
    });

    test('positions stay contiguous when a group is filtered out', () {
      seedState(membership: {'a': 3, 'b': 2}, groupCount: 3);
      // Only two of the three groups have a surviving photo.
      final groups = service.groupPhotos([_photo('a'), _photo('b')]);
      expect(groups.map((g) => g.label), ['Group 1', 'Group 2']);
    });

    test('a real label always wins over the placeholder', () {
      seedState(
        tree: _tree(labels: {3: 'Lighthouses'}),
        membership: {'a': 3, 'b': 2},
        groupCount: 3,
      );
      final groups = service.groupPhotos([_photo('a'), _photo('b')]);
      expect(groups.first.label, 'Lighthouses');
      expect(groups.last.label, 'Group 2');
    });
  });

  group('slider range', () {
    // The track is exactly the loaded tree's capacity, whatever ceiling the run
    // was built under. A run built shallower offers less until Regroup rebuilds
    // it — no dead stretch, and no drag that quietly starts a clustering pass.
    test('offers exactly what the loaded tree can cut', () {
      seedState(groupCount: 3);
      expect(service.state.value.tree!.run.maxGroups, lessThan(kClusterMinCeiling));
      expect(service.state.value.sliderMax, 3);

      seedState(tree: _tree(runMaxGroups: kClusterMinCeiling), groupCount: 3);
      expect(service.state.value.sliderMax, 3);
    });

    // Letting go of the slider must never start a clustering pass: it costs
    // seconds and discards every generated label. So the track offers only
    // positions the loaded tree can actually serve, and going finer is an
    // explicit Regroup.
    test('never offers a position the tree cannot serve', () {
      seedState(groupCount: 3);
      expect(service.state.value.sliderMax, 3);

      service.setGroupCount(40);
      expect(service.state.value.groupCount, 3,
          reason: 'clamped to what the tree holds, not left over-asking');
    });
  });

  group('setGroupCount', () {
    test('clamps to the loaded tree and ignores calls with no run', () {
      seedState(membership: const {}, groupCount: 2);
      // The tree in this fixture holds 3 groups, and that is the whole track —
      // a position beyond it would be one the view cannot render without
      // re-clustering, which only Regroup does.
      service.setGroupCount(9999);
      expect(service.state.value.groupCount, 3);
      service.setGroupCount(0);
      expect(service.state.value.groupCount, 1);

      service.state.add(const ClusterViewState(groupCount: 7));
      service.setGroupCount(2);
      expect(service.state.value.groupCount, 7, reason: 'no tree to cut');
    });
  });

  group('starting position and ceiling', () {
    // A fixed starting number is wrong at both ends — 20 groups over 200 photos
    // is uselessly coarse, and over 50,000 it is meaningless.
    test('opens somewhere sensible for the size of the library', () {
      expect(defaultGroupCountFor(200), 10);
      expect(defaultGroupCountFor(2800), 37);
      expect(defaultGroupCountFor(50000), 158);
    });

    test('degenerate libraries still produce a usable number', () {
      expect(defaultGroupCountFor(0), 1);
      expect(defaultGroupCountFor(1), 1);
      expect(defaultGroupCountFor(2), 1);
      expect(defaultGroupCountFor(8), 2);
    });

    // Below 20k the flat ceiling is plenty. Above it the starting position
    // would otherwise sit at or past the end of the track, leaving the slider
    // able to move in one direction only.
    test('the ceiling only grows once the default would crowd it', () {
      expect(maxGroupsFor(2800), kClusterMinCeiling);
      expect(maxGroupsFor(10000), kClusterMinCeiling);
      expect(maxGroupsFor(50000), 200);
      expect(maxGroupsFor(100000), 300);
      expect(maxGroupsFor(250000), 500);
    });

    test('the ceiling always leaves room above the starting position', () {
      for (final n in [0, 50, 200, 2800, 20000, 50000, 100000, 250000]) {
        expect(maxGroupsFor(n), greaterThan(defaultGroupCountFor(n)),
            reason: 'a slider that opens at its own maximum only moves one way');
        expect(maxGroupsFor(n) % 100, 0, reason: 'ceilings are round numbers');
      }
    });
  });

  group('the slider position survives a rebuild', () {
    // Reported from the app: slider moved to 82, Regroup pressed, view came
    // back at 35 — the derived starting position, recomputed over the top of a
    // deliberate choice.
    test('a user-set count is not recomputed on reload', () {
      seedState(groupCount: 3);
      service.setGroupCount(2);
      expect(service.state.value.groupCount, 2);

      // What _adopt does on a reload that is not a first show.
      service.state.add(service.state.value.copyWith(tree: _tree()));
      expect(service.state.value.groupCount, 2,
          reason: 'a regroup must keep the number the user chose');
    });

    // A rebuilt tree is deeper, and the position the user set has to survive
    // arriving at it.
    test('a chosen count survives a deeper tree arriving', () {
      seedState(groupCount: 3);
      service.setGroupCount(2);

      service.state.add(service.state.value.copyWith(
        tree: _tree(runMaxGroups: kClusterMinCeiling),
      ));
      expect(service.state.value.groupCount, 2);
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
