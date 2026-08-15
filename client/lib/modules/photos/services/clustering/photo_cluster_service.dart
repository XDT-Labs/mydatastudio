import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/clustering_isolate.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:rxdart/rxdart.dart';

/// One group as the grid renders it: the stored node plus the photos in it.
class ClusterGroupView {
  const ClusterGroupView(this.group, this.photos);

  final ClusterGroup group;
  final List<File> photos;

  String get label => group.displayLabel;

  /// Whether this group is mixed enough that a single label misrepresents it.
  /// The threshold is a judgement call from the prototype: groups below roughly
  /// 0.55 mean cosine were visibly heterogeneous (living rooms with wedding
  /// guests with kitchens), while those above read as one subject.
  bool get isMixed => group.coherence < 0.55;
}

/// What the cluster view is currently showing.
class ClusterViewState {
  const ClusterViewState({
    this.scope = const ClusterScope.all(),
    this.tree,
    this.membership = const {},
    this.groupCount = 20,
    this.isBuilding = false,
    this.progress,
    this.error,
  });

  final ClusterScope scope;
  final PhotoClusterTree? tree;

  /// file id -> deepest leaf node. Loaded once per run; changing [groupCount]
  /// resolves against this map in memory rather than re-querying.
  final Map<String, int> membership;

  final int groupCount;
  final bool isBuilding;
  final ClusteringProgress? progress;
  final String? error;

  bool get hasRun => tree != null;
  int get maxGroups => tree?.maxGroups ?? 1;

  ClusterViewState copyWith({
    ClusterScope? scope,
    PhotoClusterTree? tree,
    Map<String, int>? membership,
    int? groupCount,
    bool? isBuilding,
    ClusteringProgress? progress,
    String? error,
    bool clearError = false,
    bool clearTree = false,
  }) =>
      ClusterViewState(
        scope: scope ?? this.scope,
        tree: clearTree ? null : (tree ?? this.tree),
        membership: membership ?? this.membership,
        groupCount: groupCount ?? this.groupCount,
        isBuilding: isBuilding ?? this.isBuilding,
        progress: progress ?? this.progress,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Owns the cluster view's state: which run is loaded, how many groups the
/// slider is asking for, and when to build a new run.
///
/// A run is scoped to the drawer's current source filter, so switching sources
/// selects (or builds) a different run rather than re-filtering the current
/// one. See the photos clustering plan under `docs/plans`.
class PhotoClusterService {
  static final PhotoClusterService _instance = PhotoClusterService._();
  static PhotoClusterService get instance => _instance;

  PhotoClusterService._();

  final AppLogger logger = AppLogger(null);
  final BehaviorSubject<ClusterViewState> state =
      BehaviorSubject<ClusterViewState>.seeded(const ClusterViewState());

  ClusteringIsolate? _isolate;

  ClusterViewState get _current => state.value;

  /// Shows the run for [scope], building one if there isn't a usable one yet.
  ///
  /// Set [forceRebuild] for the explicit "regroup" action — otherwise an
  /// existing ready run is reused, which is what makes switching back to a
  /// previously visited source instant.
  Future<void> load(
    ClusterScope scope, {
    bool forceRebuild = false,
    int maxGroups = 48,
  }) async {
    final db = DatabaseManager.instance.database;
    if (db == null) {
      state.add(_current.copyWith(error: 'Database not ready'));
      return;
    }

    state.add(_current.copyWith(
      scope: scope,
      clearError: true,
      clearTree: true,
      membership: const {},
    ));

    final repo = PhotoClusterRepository(db);

    if (!forceRebuild) {
      final existing = await repo.latestReadyRun(scope);
      if (existing != null) {
        await _adopt(repo, existing.id);
        return;
      }
    }

    await _build(repo, db, scope, maxGroups);
  }

  /// Moves the slider. Pure in-memory re-cut — no query, no clustering — so
  /// this is safe to call on every drag frame.
  void setGroupCount(int k) {
    final tree = _current.tree;
    if (tree == null) return;
    state.add(_current.copyWith(groupCount: k.clamp(1, tree.maxGroups)));
  }

  /// Buckets [photos] into the groups at the current slider position, largest
  /// group first.
  ///
  /// Photos with no membership row are dropped rather than piled into a
  /// catch-all: they were scanned after this run was built, and inventing a
  /// group for them would misrepresent the clustering. The caller reports the
  /// shortfall as coverage instead — see [uncoveredCount].
  List<ClusterGroupView> groupPhotos(List<File> photos) {
    final st = _current;
    final tree = st.tree;
    if (tree == null) return const [];

    final groups = tree.groupsAt(st.groupCount);
    final buckets = {for (final g in groups) g.nodeId: <File>[]};

    for (final photo in photos) {
      final leaf = st.membership[photo.id];
      if (leaf == null) continue;
      final groupId = tree.groupIdForLeaf(leaf, st.groupCount);
      buckets[groupId]?.add(photo);
    }

    return [
      for (final g in groups)
        if (buckets[g.nodeId]!.isNotEmpty)
          ClusterGroupView(g, buckets[g.nodeId]!),
    ];
  }

  /// How many of [photos] this run has no place for — photos added since it was
  /// built, or still waiting on an embedding. Surfaced in the UI rather than
  /// hidden, so the grid never silently omits photos.
  int uncoveredCount(List<File> photos) {
    final membership = _current.membership;
    if (membership.isEmpty) return photos.length;
    return photos.where((p) => !membership.containsKey(p.id)).length;
  }

  Future<void> _adopt(PhotoClusterRepository repo, String runId) async {
    final tree = await repo.loadTree(runId);
    if (tree == null) {
      state.add(_current.copyWith(error: 'Could not load groups'));
      return;
    }
    final membership = await repo.loadMembership(runId);
    state.add(_current.copyWith(
      tree: tree,
      membership: membership,
      groupCount: _current.groupCount.clamp(1, tree.maxGroups),
      isBuilding: false,
      clearError: true,
    ));
  }

  Future<void> _build(
    PhotoClusterRepository repo,
    AppDatabase db,
    ClusterScope scope,
    int maxGroups,
  ) async {
    final storagePath = db.path;
    final dbName = db.name;
    final token = RootIsolateToken.instance;
    if (storagePath == null || dbName == null || token == null) {
      state.add(_current.copyWith(error: 'Database not ready'));
      return;
    }

    state.add(_current.copyWith(isBuilding: true, clearError: true));
    _isolate = ClusteringIsolate(logger: logger);

    try {
      final run = await _isolate!.run(
        scope: scope,
        storagePath: storagePath,
        dbName: dbName,
        token: token,
        maxGroups: maxGroups,
        onProgress: (p) => state.add(_current.copyWith(progress: p)),
      );
      await _adopt(repo, run.id);
    } on ClusteringFailure catch (e) {
      logger.w('PhotoClusterService: clustering failed — ${e.message}');
      state.add(_current.copyWith(isBuilding: false, error: e.message));
    } catch (e, stack) {
      logger.e('PhotoClusterService: clustering error', error: e, stackTrace: stack);
      state.add(_current.copyWith(
        isBuilding: false,
        error: 'Could not group photos',
      ));
    } finally {
      _isolate = null;
    }
  }

  Future<void> dispose() async {
    await _isolate?.stop();
    _isolate = null;
  }
}
