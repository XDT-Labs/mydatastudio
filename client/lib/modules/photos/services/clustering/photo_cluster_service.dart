import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/cluster_label_service.dart';
import 'package:mydatastudio/modules/photos/services/clustering/clustering_isolate.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_repository.dart';
import 'package:rxdart/rxdart.dart';

/// Ceiling on how many groups a run can be cut into — the slider's upper bound.
///
/// Built up front rather than grown on demand. Clustering cost is linear in
/// photo count but only logarithmic in group count: on a 2,808-photo library,
/// 16 groups took 2.4s and 96 took 3.6s, so reaching 100 costs a few hundred
/// milliseconds once and makes every slider position instant. Growing the tree
/// when the user drags past its end would trade that for a multi-second stall
/// mid-gesture, and would invalidate every label each time it rebuilt.
///
/// A run tops out below this when the data runs out of meaningful splits —
/// identical or near-identical photos cannot be divided further — and the
/// slider then matches whatever the tree actually produced.
const int kClusterMaxGroups = 100;

/// One group as the grid renders it: the stored node plus the photos in it.
class ClusterGroupView {
  const ClusterGroupView(this.group, this.photos, this.position);

  final ClusterGroup group;
  final List<File> photos;

  /// 1-based position among the groups currently shown.
  final int position;

  /// The header text.
  ///
  /// The placeholder counts by position, not by `nodeId`. Node ids index the
  /// whole split tree — 95 nodes for a 48-group run — so numbering by them put
  /// a header reading "Group 80" in a view containing 48 groups, which reads as
  /// a count and is wrong. Position always matches what is on screen.
  String get label => group.label?.isNotEmpty == true
      ? group.label!
      : 'Group $position';

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

  /// Upper bound the slider offers.
  ///
  /// Normally the tree's real capacity, so there is never a dead stretch at the
  /// end of the track. But a run built under an older, lower ceiling can be
  /// rebuilt deeper, and refusing to offer that would strand the user on a
  /// coarseness they cannot escape without knowing to press Regroup. In that
  /// case the slider offers the current ceiling and dragging past capacity
  /// rebuilds — see [PhotoClusterService.commitGroupCount].
  int get sliderMax {
    final run = tree?.run;
    if (run == null) return 1;
    return run.maxGroups < kClusterMaxGroups
        ? kClusterMaxGroups
        : tree!.maxGroups;
  }

  /// Whether [groupCount] is finer than this tree can actually cut.
  bool get needsDeeperTree => tree != null && groupCount > tree!.maxGroups;

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
  StreamSubscription<String>? _labelSub;

  ClusterViewState get _current => state.value;

  /// Shows the run for [scope], building one if there isn't a usable one yet.
  ///
  /// Set [forceRebuild] for the explicit "regroup" action — otherwise an
  /// existing ready run is reused, which is what makes switching back to a
  /// previously visited source instant.
  Future<void> load(
    ClusterScope scope, {
    bool forceRebuild = false,
    int maxGroups = kClusterMaxGroups,
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
  ///
  /// Accepts a k beyond the tree's capacity so the thumb tracks the finger
  /// rather than sticking; the grid keeps showing the finest cut available
  /// until [commitGroupCount] rebuilds on release.
  void setGroupCount(int k) {
    final st = _current;
    if (st.tree == null) return;
    state.add(st.copyWith(groupCount: k.clamp(1, st.sliderMax)));
  }

  /// Called when the user lets go of the slider.
  ///
  /// Rebuilds only when they asked for a finer cut than this tree can produce,
  /// and only on release — rebuilding mid-drag would fire a clustering pass per
  /// frame. A no-op in the common case, which is why the drag itself stays free.
  Future<void> commitGroupCount() async {
    final st = _current;
    if (!st.needsDeeperTree || st.isBuilding) return;
    logger.i(
      'PhotoClusterService: ${st.groupCount} groups requested, tree holds '
      '${st.maxGroups} — rebuilding deeper',
    );
    await load(st.scope, forceRebuild: true);
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

    final views = <ClusterGroupView>[];
    for (final g in groups) {
      final photos = buckets[g.nodeId]!;
      if (photos.isEmpty) continue;
      views.add(ClusterGroupView(g, photos, views.length + 1));
    }
    return views;
  }

  /// How many of [photos] this run has no place for — photos added since it was
  /// built, or still waiting on an embedding. Surfaced in the UI rather than
  /// hidden, so the grid never silently omits photos.
  int uncoveredCount(List<File> photos) {
    final membership = _current.membership;
    if (membership.isEmpty) return photos.length;
    return photos.where((p) => !membership.containsKey(p.id)).length;
  }

  Future<void> _adopt(
    PhotoClusterRepository repo,
    String runId, {
    bool startLabelling = true,
  }) async {
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

    if (startLabelling) _startLabelling(repo, runId);
  }

  /// Names the run's groups in the background, refreshing the tree as each
  /// label lands.
  ///
  /// Not awaited: the grid is usable immediately with "Group N" headers, and
  /// labelling a whole run is minutes of serialised vision calls. Blocking the
  /// view on it would be the difference between a slow feature and a broken
  /// one.
  void _startLabelling(PhotoClusterRepository repo, String runId) {
    // A run whose groups are all named already needs no pass, and re-entering
    // would just reload the tree for nothing.
    final tree = _current.tree;
    if (tree != null &&
        tree.allGroups.every(
          (g) => g.labelStatus != ClusterLabelStatus.pending,
        )) {
      return;
    }

    _labelSub?.cancel();
    _labelSub = ClusterLabelService.instance.onLabelled.listen((labelledRun) {
      // Ignore late arrivals from a run the user has already navigated away
      // from — adopting them would swap the visible tree out from under them.
      if (labelledRun != _current.tree?.run.id) return;
      _adopt(repo, labelledRun, startLabelling: false);
    });

    ClusterLabelService.instance.cancel();
    unawaited(ClusterLabelService.instance.labelRun(repo, runId));
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
    ClusterLabelService.instance.cancel();
    await _labelSub?.cancel();
    _labelSub = null;
  }
}
