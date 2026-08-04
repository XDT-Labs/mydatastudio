import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/date_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_grid.dart';
import 'package:mydatastudio/modules/photos/widgets/views/timeline_quick_jump.dart';

/// Chronological timeline view widget with year-month grouping and quick-jump sidebar.
class PhotoTimelineView extends StatefulWidget {
  const PhotoTimelineView({
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
  State<PhotoTimelineView> createState() => _PhotoTimelineViewState();
}

class _PhotoTimelineViewState extends State<PhotoTimelineView> {
  late ScrollController _scrollController;
  bool _createdOwnController = false;

  int _activeIndex = 0;
  List<double> _sectionOffsets = [];
  final Map<String, GlobalKey> _headerKeys = {};

  StreamSubscription<double>? _gridSizeSub;
  double _gridItemSize = 160.0;

  @override
  void initState() {
    super.initState();
    if (widget.scrollController != null) {
      _scrollController = widget.scrollController!;
    } else {
      _scrollController = ScrollController();
      _createdOwnController = true;
    }
    _scrollController.addListener(_onScroll);

    _gridItemSize = ViewStateService.instance.gridItemSize.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gridSizeSub = ViewStateService.instance.gridItemSize.listen((size) {
        if (mounted) setState(() => _gridItemSize = size);
      });
    });
  }

  @override
  void didUpdateWidget(PhotoTimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.scrollController != oldWidget.scrollController) {
      _scrollController.removeListener(_onScroll);
      if (_createdOwnController) {
        _scrollController.dispose();
        _createdOwnController = false;
      }
      if (widget.scrollController != null) {
        _scrollController = widget.scrollController!;
      } else {
        _scrollController = ScrollController();
        _createdOwnController = true;
      }
      _scrollController.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    if (_createdOwnController) {
      _scrollController.dispose();
    }
    _gridSizeSub?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _sectionOffsets.isEmpty) return;
    final offset = _scrollController.offset;

    int newIndex = 0;
    for (int i = 0; i < _sectionOffsets.length; i++) {
      if (offset >= _sectionOffsets[i] - 10) {
        newIndex = i;
      } else {
        break;
      }
    }

    if (newIndex != _activeIndex) {
      setState(() {
        _activeIndex = newIndex;
      });
    }
  }

  void _jumpToSection(int index, List<String> monthLabels) {
    if (index < 0 || index >= _sectionOffsets.length) return;
    if (!_scrollController.hasClients) return;

    final targetOffset = _sectionOffsets[index].clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );

    // Estimated offsets drift from real layout once lazily-built grid
    // content is involved, so jump to the estimate first, then let the
    // header's own GlobalKey correct the final position once it's laid out.
    _scrollController.jumpTo(targetOffset);

    final label = index < monthLabels.length ? monthLabels[index] : null;
    final key = label != null ? _headerKeys[label] : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = key?.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    });
  }

  Map<String, List<File>> _groupAndSortFiles(List<File> files) {
    final sorted = List<File>.from(files)
      ..sort((a, b) => b.dateCreated.compareTo(a.dateCreated));

    final Map<String, List<File>> groups = {};
    final DateFormat formatter = DateFormat('MMMM yyyy');

    for (final file in sorted) {
      final key = formatter.format(file.dateCreated);
      groups.putIfAbsent(key, () => []).add(file);
    }
    return groups;
  }

  List<double> _calculateSectionOffsets(
    Map<String, List<File>> groups,
    double mainWidth,
    int columns,
  ) {
    final List<double> offsets = [];
    double currentOffset = 0.0;

    final usableGridWidth = max(0.0, mainWidth - 16.0);
    final itemWidth = (usableGridWidth - (columns - 1) * 8.0) / columns;
    final itemHeight = itemWidth;

    for (final monthFiles in groups.values) {
      offsets.add(currentOffset);

      const headerHeight = 40.0;
      final rows = (monthFiles.length / columns).ceil();
      final gridHeight = rows == 0
          ? 0.0
          : 16.0 + rows * itemHeight + (rows - 1) * 8.0;

      currentOffset += headerHeight + gridHeight;
    }

    return offsets;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.files.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.photo_library,
                    size: 64,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No photos found',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          TimelineQuickJump(
            monthLabels: const [],
            onJumpTo: (_) {},
          ),
        ],
      );
    }

    final groups = _groupAndSortFiles(widget.files);
    final monthLabels = groups.keys.toList();
    final Map<String, int> photoCounts = {
      for (final entry in groups.entries) entry.key: entry.value.length
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final mainWidth = max(0.0, constraints.maxWidth - 48.0);
        final columns = PhotoGrid.getColumnCount(mainWidth, itemSize: _gridItemSize);

        _sectionOffsets = _calculateSectionOffsets(groups, mainWidth, columns);

        final List<Widget> slivers = [];

        void selectAllForGroup(List<File> monthFiles, bool val) {
          if (val) {
            SelectionService.instance.selectAll(
              monthFiles.map((f) => f.id).toList(),
            );
          } else {
            for (final f in monthFiles) {
              if (widget.selectedIds.contains(f.id)) {
                SelectionService.instance.toggle(f.id);
              }
            }
          }
        }

        groups.forEach((monthYear, monthFiles) {
          final isGroupAllSelected = monthFiles.every(
            (f) => widget.selectedIds.contains(f.id),
          );

          // Plain inline header (not pinned): the single overlay header
          // below provides the "sticky" appearance without the stacking
          // bug multiple pinned SliverPersistentHeaders would cause.
          slivers.add(
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: _headerKeys.putIfAbsent(monthYear, () => GlobalKey()),
                child: SizedBox(
                  height: 40.0,
                  child: DateSectionHeader(
                    dateLabel: monthYear,
                    itemCount: monthFiles.length,
                    isSelected: isGroupAllSelected,
                    onSelectAll: (val) => selectAllForGroup(monthFiles, val),
                  ),
                ),
              ),
            ),
          );

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
                    final file = monthFiles[index];
                    final isSelected = widget.selectedIds.contains(file.id);

                    return buildWiredPhotoGridTile(
                      file: file,
                      isSelected: isSelected,
                      allFiles: widget.files,
                      onTapTile: widget.onTapTile,
                      onSelectTile: widget.onSelectTile,
                      onToggleFavoriteTile: widget.onToggleFavoriteTile,
                      onOpenLightboxTile: widget.onOpenLightboxTile,
                      onOpenInfoTile: widget.onOpenInfoTile,
                    );
                  },
                  childCount: monthFiles.length,
                ),
              ),
            ),
          );
        });

        final activeIndex = _activeIndex.clamp(0, monthLabels.length - 1);
        final activeMonth = monthLabels[activeIndex];
        final activeFiles = groups[activeMonth]!;
        final isActiveGroupAllSelected = activeFiles.every(
          (f) => widget.selectedIds.contains(f.id),
        );

        return Row(
          children: [
            Expanded(
              child: Stack(
                children: [
                  CustomScrollView(
                    controller: _scrollController,
                    slivers: slivers,
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SizedBox(
                      height: 40.0,
                      child: DateSectionHeader(
                        dateLabel: activeMonth,
                        itemCount: activeFiles.length,
                        isSelected: isActiveGroupAllSelected,
                        onSelectAll: (val) => selectAllForGroup(activeFiles, val),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TimelineQuickJump(
              monthLabels: monthLabels,
              activeIndex: _activeIndex,
              onJumpTo: (index) => _jumpToSection(index, monthLabels),
              photoCounts: photoCounts,
            ),
          ],
        );
      },
    );
  }
}
