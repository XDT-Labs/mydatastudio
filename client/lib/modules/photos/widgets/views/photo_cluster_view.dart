import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_cluster.dart';
import 'package:mydatastudio/modules/photos/services/clustering/clustering_isolate.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/cluster_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_grid.dart';

/// Photos grouped by visual similarity instead of by date.
///
/// Renders the same tiles as [PhotoGrid] under group headers rather than month
/// headers. The group count comes from the slider in the toolbar; changing it
/// re-cuts the stored tree in memory, so this widget just rebuilds — no query,
/// no re-clustering.
class PhotoClusterView extends StatefulWidget {
  const PhotoClusterView({
    super.key,
    required this.files,
    required this.selectedIds,
    this.scrollController,
    this.onTapTile,
    this.onSelectTile,
    this.onToggleFavoriteTile,
    this.onOpenLightboxTile,
    this.onOpenInfoTile,
  });

  final List<File> files;
  final Set<String> selectedIds;
  final ScrollController? scrollController;
  final ValueChanged<File>? onTapTile;
  final ValueChanged<File>? onSelectTile;
  final ValueChanged<File>? onToggleFavoriteTile;
  final ValueChanged<File>? onOpenLightboxTile;
  final ValueChanged<File>? onOpenInfoTile;

  @override
  State<PhotoClusterView> createState() => _PhotoClusterViewState();
}

class _PhotoClusterViewState extends State<PhotoClusterView> {
  late ScrollController _scrollController;
  bool _createdOwnController = false;

  StreamSubscription<ClusterViewState>? _stateSub;
  StreamSubscription<double>? _gridSizeSub;

  ClusterViewState _state = const ClusterViewState();
  double _gridItemSize = 160.0;

  /// Node ids the user has collapsed.
  ///
  /// Keyed by node rather than by position so a group stays collapsed when the
  /// slider moves and it keeps its identity. Splitting a collapsed group drops
  /// the collapse — its children are different groups the user has not made a
  /// decision about — which falls out of keying on node id.
  final Set<int> _collapsed = {};

  @override
  void initState() {
    super.initState();
    if (widget.scrollController != null) {
      _scrollController = widget.scrollController!;
    } else {
      _scrollController = ScrollController();
      _createdOwnController = true;
    }

    _state = PhotoClusterService.instance.state.value;
    _stateSub = PhotoClusterService.instance.state.listen((s) {
      if (mounted) setState(() => _state = s);
    });

    // Shared with the timeline grid: tile size is a property of the photo grid,
    // not of one view, so the toolbar's size slider applies here too.
    _gridItemSize = ViewStateService.instance.gridItemSize.value;
    _gridSizeSub = ViewStateService.instance.gridItemSize.listen((size) {
      if (mounted) setState(() => _gridItemSize = size);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _gridSizeSub?.cancel();
    if (_createdOwnController) _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state.isBuilding) return _buildProgress(context);
    if (_state.error != null) return _buildMessage(context, _state.error!);
    if (!_state.hasRun) {
      return _buildMessage(context, 'No groups yet.');
    }

    final groups = PhotoClusterService.instance.groupPhotos(widget.files);
    if (groups.isEmpty) {
      return _buildMessage(
        context,
        'None of the photos in this view are part of the current grouping. '
        'Regroup to include them.',
      );
    }

    final uncovered = PhotoClusterService.instance.uncoveredCount(widget.files);

    return LayoutBuilder(
      builder: (context, constraints) {
        final mainWidth = max(0.0, constraints.maxWidth - 48.0);
        final columns =
            PhotoGrid.getColumnCount(mainWidth, itemSize: _gridItemSize);

        final slivers = <Widget>[];

        // Coverage first, and only when there is a shortfall: a grid that
        // silently drops photos is worse than one that says how many and why.
        if (uncovered > 0) {
          slivers.add(
            SliverToBoxAdapter(child: _CoverageNotice(count: uncovered)),
          );
        }

        for (final group in groups) {
          final photos = group.photos;
          final allSelected =
              photos.every((f) => widget.selectedIds.contains(f.id));
          final isCollapsed = _collapsed.contains(group.group.nodeId);

          slivers.add(
            SliverToBoxAdapter(
              child: ClusterSectionHeader(
                label: group.label,
                itemCount: photos.length,
                isSelected: allSelected,
                isMixed: group.isMixed,
                isCollapsed: isCollapsed,
                isLabelPending:
                    group.group.labelStatus == ClusterLabelStatus.pending,
                onToggleCollapsed: () => setState(() {
                  if (!_collapsed.remove(group.group.nodeId)) {
                    _collapsed.add(group.group.nodeId);
                  }
                }),
                onSelectAll: (val) {
                  if (val) {
                    SelectionService.instance
                        .selectAll(photos.map((f) => f.id).toList());
                  } else {
                    SelectionService.instance
                        .deselectMany(photos.map((f) => f.id));
                  }
                },
              ),
            ),
          );

          // Collapsed: header only. The photos are dropped from the sliver
          // list rather than hidden with zero height, so a collapsed group
          // costs nothing to scroll past.
          if (isCollapsed) continue;

          slivers.add(
            SliverPadding(
              padding: const EdgeInsets.all(8.0),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 8.0,
                  mainAxisSpacing: 8.0,
                  childAspectRatio: 1.0,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final file = photos[index];
                    return buildWiredPhotoGridTile(
                      file: file,
                      isSelected: widget.selectedIds.contains(file.id),
                      allFiles: widget.files,
                      onTapTile: widget.onTapTile,
                      onSelectTile: widget.onSelectTile,
                      onToggleFavoriteTile: widget.onToggleFavoriteTile,
                      onOpenLightboxTile: widget.onOpenLightboxTile,
                      onOpenInfoTile: widget.onOpenInfoTile,
                    );
                  },
                  childCount: photos.length,
                ),
              ),
            ),
          );
        }

        return CustomScrollView(
          controller: _scrollController,
          slivers: slivers,
        );
      },
    );
  }

  Widget _buildProgress(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _state.progress;

    // Determinate once the clustering phase reports splits, because that phase
    // is the long one and a spinner with no end in sight reads as a hang.
    final fraction = progress?.phase == ClusteringPhase.clustering
        ? progress?.fraction
        : null;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 180,
            child: LinearProgressIndicator(value: fraction),
          ),
          const SizedBox(height: 16),
          Text(
            switch (progress?.phase) {
              ClusteringPhase.loading => 'Reading photo fingerprints…',
              ClusteringPhase.clustering => 'Finding groups…',
              ClusteringPhase.saving => 'Saving groups…',
              null => 'Grouping photos…',
            },
            style: theme.textTheme.titleMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, String message) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.workspaces_outline,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tells the user how many photos this grouping has no place for.
///
/// Photos scanned since the run was built, or still waiting on an embedding,
/// have no group. They are left out of the grid rather than dumped into a
/// catch-all bucket that would misrepresent the clustering — so the count has
/// to be visible, or the view would appear to be missing photos for no reason.
class _CoverageNotice extends StatelessWidget {
  const _CoverageNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$count ${count == 1 ? 'photo is' : 'photos are'} not in a group '
              'yet — added since these groups were built, or still being '
              'analysed. Regroup to include them.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
