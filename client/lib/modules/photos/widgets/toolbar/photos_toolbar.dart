import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/album_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/import_dialog.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart';
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

  void _showKeyboardShortcuts(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => const KeyboardShortcutsModal(),
    );
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
              ],
              selected: {_currentViewMode},
              onSelectionChanged: (newSelection) {
                if (newSelection.isNotEmpty) {
                  ViewStateService.instance.setViewMode(newSelection.first);
                }
              },
            ),

            const SizedBox(width: 8),

            // Import Button
            IconButton(
              icon: const Icon(Icons.file_upload_outlined),
              tooltip: 'Import Photos',
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (context) => const ImportDialog(),
                );
              },
            ),

            // Shortcuts Button
            IconButton(
              icon: const Icon(Icons.keyboard_outlined),
              tooltip: 'Keyboard Shortcuts',
              onPressed: () => _showKeyboardShortcuts(context),
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
            final count = _selectedIds.length;
            final confirm = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
                title: Text('Delete $count item(s)?'),
                content: const Text(
                  'Are you sure you want to move selected photos to trash?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(ctx).colorScheme.error,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Delete'),
                  ),
                ],
              ),
            );
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
