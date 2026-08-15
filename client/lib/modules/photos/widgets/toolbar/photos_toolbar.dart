import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/clustering/photo_cluster_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/album_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/hide_photos_confirm_dialog.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/filter_dropdown.dart';

/// Module-specific top toolbar widget for the Photos app.
///
/// Supports normal view controls (search, filter dropdown, view mode switcher,
/// shortcuts modal) and batch selection controls when items are selected.
class PhotosToolbar extends StatefulWidget {
  const PhotosToolbar({super.key});

  @override
  State<PhotosToolbar> createState() => _PhotosToolbarState();
}

class _PhotosToolbarState extends State<PhotosToolbar> {
  late final TextEditingController _searchController;
  Timer? _debounceTimer;

  StreamSubscription? _selectionSub;
  StreamSubscription? _filterSub;
  StreamSubscription? _viewModeSub;
  StreamSubscription? _photosSub;
  StreamSubscription? _gridSizeSub;

  Set<String> _selectedIds = {};
  PhotoFilter _activeFilter = const PhotoFilter();
  PhotoViewMode _currentViewMode = PhotoViewMode.grid;
  List<File> _files = [];
  double _gridItemSize = 160.0;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: ViewStateService.instance.activeFilter.value.searchQuery,
    );

    _selectedIds = SelectionService.instance.selectedIds.value;
    _activeFilter = ViewStateService.instance.activeFilter.value;
    _currentViewMode = ViewStateService.instance.viewMode.value;
    _files = PhotosService.instance.sink.valueOrNull ?? [];
    _gridItemSize = ViewStateService.instance.gridItemSize.value;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectionSub = SelectionService.instance.selectedIds.listen((selected) {
        if (mounted) setState(() => _selectedIds = selected);
      });

      _filterSub = ViewStateService.instance.activeFilter.listen((filter) {
        if (mounted) {
          setState(() => _activeFilter = filter);
          if (_searchController.text != filter.searchQuery) {
            _searchController.text = filter.searchQuery;
          }
        }
      });

      _viewModeSub = ViewStateService.instance.viewMode.listen((mode) {
        if (mounted) setState(() => _currentViewMode = mode);
      });

      _photosSub = PhotosService.instance.sink.listen((photos) {
        if (mounted) setState(() => _files = photos);
      });

      _gridSizeSub = ViewStateService.instance.gridItemSize.listen((size) {
        if (mounted) setState(() => _gridItemSize = size);
      });
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.dispose();
    _selectionSub?.cancel();
    _filterSub?.cancel();
    _viewModeSub?.cancel();
    _photosSub?.cancel();
    _gridSizeSub?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      final current = ViewStateService.instance.activeFilter.value;
      if (current.searchQuery != query) {
        ViewStateService.instance.updateFilter(
          current.copyWith(searchQuery: query),
        );
      }
    });
  }

  Widget _buildNormalToolbar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 750;
        final sliderWidth = isCompact ? 60.0 : 100.0;

        return Row(
          children: [
            // Search TextField
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 240, minWidth: 100),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    hintText: 'Search photos...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: colorScheme.primary),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),

            // Filter Dropdown
            FilterDropdown(
              mediaType: _activeFilter.mediaType,
              onlyFavorites: _activeFilter.onlyFavorites,
              sortBy: _activeFilter.sortBy.name,
              onMediaTypeChanged: (type) {
                ViewStateService.instance.updateFilter(
                  _activeFilter.copyWith(mediaType: type),
                );
              },
              onFavoritesChanged: (fav) {
                ViewStateService.instance.updateFilter(
                  _activeFilter.copyWith(onlyFavorites: fav),
                );
              },
              onSortChanged: (sortStr) {
                final sortEnum = PhotoSortOrder.values.firstWhere(
                  (e) => e.name == sortStr,
                  orElse: () => PhotoSortOrder.dateDesc,
                );
                ViewStateService.instance.updateFilter(
                  _activeFilter.copyWith(sortBy: sortEnum),
                );
              },
            ),

            if (_currentViewMode == PhotoViewMode.grid) ...[
              if (constraints.maxWidth >= 650) ...[
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Image Grid Size',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.photo_size_select_small,
                        size: 16,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      SizedBox(
                        width: sliderWidth,
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 2,
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6),
                          ),
                          child: Slider(
                            value: _gridItemSize,
                            min: 100.0,
                            max: 320.0,
                            onChanged: (val) {
                              setState(() {
                                _gridItemSize = val;
                              });
                            },
                            onChangeEnd: (val) {
                              ViewStateService.instance.setGridItemSize(val);
                            },
                          ),
                        ),
                      ),
                      Icon(
                        Icons.photo_size_select_large,
                        size: 20,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ],
            ],

            if (_currentViewMode == PhotoViewMode.clusters) ...[
              if (constraints.maxWidth >= 650) ...[
                const SizedBox(width: 8),
                const _GroupCountSlider(),
              ],
              const _RegroupButton(),
            ],

            const Spacer(),

            // View Mode SegmentedButton
            SegmentedButton<PhotoViewMode>(
              segments: const [
                ButtonSegment<PhotoViewMode>(
                  value: PhotoViewMode.grid,
                  icon: Icon(Icons.grid_view, size: 18),
                  tooltip: 'Grid View',
                ),
                ButtonSegment<PhotoViewMode>(
                  value: PhotoViewMode.list,
                  icon: Icon(Icons.view_list, size: 18),
                  tooltip: 'List View',
                ),
                ButtonSegment<PhotoViewMode>(
                  value: PhotoViewMode.map,
                  icon: Icon(Icons.map, size: 18),
                  tooltip: 'Map View',
                ),
                ButtonSegment<PhotoViewMode>(
                  value: PhotoViewMode.clusters,
                  icon: Icon(Icons.workspaces_outline, size: 18),
                  tooltip: 'Group by Similarity',
                ),
              ],
              selected: {_currentViewMode},
              onSelectionChanged: (newSelection) {
                if (newSelection.isNotEmpty) {
                  ViewStateService.instance.setViewMode(newSelection.first);
                }
              },
            ),
          ],
        );
      },
    );
  }

  Widget _buildBatchToolbar(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Row(
      children: [
        Text(
          '${_selectedIds.length} selected',
          style: textTheme.titleSmall?.copyWith(
            color: colorScheme.onPrimaryContainer,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 16),
        TextButton(
          onPressed: () {
            final allIds = _files.map((f) => f.id).toList();
            SelectionService.instance.selectAll(allIds);
          },
          child: Text(
            'Select All',
            style: TextStyle(color: colorScheme.onPrimaryContainer),
          ),
        ),
        TextButton(
          onPressed: () {
            SelectionService.instance.deselectAll();
          },
          child: Text(
            'Deselect',
            style: TextStyle(color: colorScheme.onPrimaryContainer),
          ),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.playlist_add),
          tooltip: 'Add to Album',
          color: colorScheme.onPrimaryContainer,
          onPressed: () {
            showDialog<void>(
              context: context,
              builder: (context) => AlbumModal(selectedFileIds: _selectedIds),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.download),
          tooltip: 'Download',
          color: colorScheme.onPrimaryContainer,
          onPressed: () {
            BatchActionService.instance.downloadSelected(_selectedIds);
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete',
          color: colorScheme.error,
          onPressed: () async {
            final selectedFiles =
                _files.where((f) => _selectedIds.contains(f.id)).toList();
            final confirm =
                await showHidePhotosConfirmDialog(context, selectedFiles);
            if (confirm == true) {
              await BatchActionService.instance.deleteSelected(_selectedIds);
            }
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isBatchMode = _selectedIds.isNotEmpty;

    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isBatchMode
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outlineVariant,
            width: 1.0,
          ),
        ),
      ),
      child: isBatchMode
          ? _buildBatchToolbar(context)
          : _buildNormalToolbar(context),
    );
  }
}

/// Slider controlling how many groups the cluster view shows.
///
/// Changing it re-cuts the stored split tree in memory — no query, no
/// re-clustering — so it updates live on drag rather than waiting for release.
/// That is the whole reason the clustering is bisecting rather than flat: with
/// flat k-means each notch would be an independent solve, and photos would
/// scatter across the grid as the user dragged.
class _GroupCountSlider extends StatefulWidget {
  const _GroupCountSlider();

  @override
  State<_GroupCountSlider> createState() => _GroupCountSliderState();
}

class _GroupCountSliderState extends State<_GroupCountSlider> {
  StreamSubscription<ClusterViewState>? _sub;
  ClusterViewState _state = const ClusterViewState();

  @override
  void initState() {
    super.initState();
    _state = PhotoClusterService.instance.state.value;
    _sub = PhotoClusterService.instance.state.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Nothing to cut until a run exists, and a one-group tree has no choice to
    // offer — showing a dead control in either case just invites confusion.
    if (!_state.hasRun || _state.sliderMax < 2) return const SizedBox.shrink();
    final max = _state.sliderMax;

    return Tooltip(
      message: 'Number of groups',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspaces_outline,
              size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          SizedBox(
            width: 120,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                value: _state.groupCount.clamp(1, max).toDouble(),
                min: 1,
                max: max.toDouble(),
                divisions: max - 1,
                label: '${_state.groupCount}',
                onChanged: (val) =>
                    PhotoClusterService.instance.setGroupCount(val.round()),
                // Only on release: past the tree's capacity this rebuilds, and
                // doing that per drag frame would fire a clustering pass a
                // frame.
                onChangeEnd: (_) =>
                    PhotoClusterService.instance.commitGroupCount(),
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text(
              '${_state.groupCount}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    // Dimmed while the grid is still showing a coarser cut than
                    // was asked for, so the number does not claim to describe
                    // what is on screen until the rebuild lands.
                    color: _state.needsDeeperTree
                        ? colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                        : colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Rebuilds the groups for the current source from scratch.
///
/// Needed for two things that are otherwise dead ends. Photos scanned since the
/// run was built have no group and are reported as uncovered rather than
/// guessed at; and a group whose name could not be generated is not retried, so
/// a run labelled while the aiserver was down stays a wall of "Group N".
/// Rebuilding produces a fresh tree whose groups are all unnamed again, which
/// the labeller then works through.
class _RegroupButton extends StatefulWidget {
  const _RegroupButton();

  @override
  State<_RegroupButton> createState() => _RegroupButtonState();
}

class _RegroupButtonState extends State<_RegroupButton> {
  StreamSubscription<ClusterViewState>? _sub;
  ClusterViewState _state = const ClusterViewState();

  @override
  void initState() {
    super.initState();
    _state = PhotoClusterService.instance.state.value;
    _sub = PhotoClusterService.instance.state.listen((s) {
      if (mounted) setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Disabled mid-build rather than hidden: a control that vanishes while the
    // thing it controls is working reads as a glitch.
    final busy = _state.isBuilding;
    return IconButton(
      icon: const Icon(Icons.refresh),
      iconSize: 18,
      tooltip: busy ? 'Grouping photos…' : 'Regroup photos',
      onPressed: busy
          ? null
          : () => PhotoClusterService.instance.load(
                _state.scope,
                forceRebuild: true,
              ),
    );
  }
}
