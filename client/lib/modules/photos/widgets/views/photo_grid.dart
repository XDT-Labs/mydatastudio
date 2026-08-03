import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/date_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';

/// Main photo grid view component with virtualized date-grouped sections.
class PhotoGrid extends StatefulWidget {
  const PhotoGrid({
    super.key,
    required this.files,
    required this.selectedIds,
    this.onTapTile,
    this.onSelectTile,
    this.onToggleFavoriteTile,
    this.onOpenLightboxTile,
    this.onOpenInfoTile,
  });

  final List<File> files;
  final Set<String> selectedIds;
  final ValueChanged<File>? onTapTile;
  final ValueChanged<File>? onSelectTile;
  final ValueChanged<File>? onToggleFavoriteTile;
  final ValueChanged<File>? onOpenLightboxTile;
  final ValueChanged<File>? onOpenInfoTile;

  static int getColumnCount(double width, {double itemSize = 160.0}) {
    final cols = (width / itemSize).round();
    return cols.clamp(1, 12);
  }

  @override
  State<PhotoGrid> createState() => _PhotoGridState();
}

class _PhotoGridState extends State<PhotoGrid> {
  StreamSubscription<double>? _gridSizeSub;
  double _gridItemSize = 160.0;

  @override
  void initState() {
    super.initState();
    _gridItemSize = ViewStateService.instance.gridItemSize.value;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gridSizeSub = ViewStateService.instance.gridItemSize.listen((size) {
        if (mounted) setState(() => _gridItemSize = size);
      });
    });
  }

  @override
  void dispose() {
    _gridSizeSub?.cancel();
    super.dispose();
  }

  Map<String, List<File>> _groupByMonthYear(List<File> files) {
    final Map<String, List<File>> groups = {};
    final DateFormat formatter = DateFormat('MMMM yyyy');

    for (final file in files) {
      final key = formatter.format(file.dateCreated);
      groups.putIfAbsent(key, () => []).add(file);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.files.isEmpty) {
      return Center(
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
      );
    }

    final groups = _groupByMonthYear(widget.files);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = PhotoGrid.getColumnCount(constraints.maxWidth, itemSize: _gridItemSize);

        final List<Widget> slivers = [];

        groups.forEach((monthYear, monthFiles) {
          final isGroupAllSelected = monthFiles.every(
            (f) => widget.selectedIds.contains(f.id),
          );

          // 1. Date section header
          slivers.add(
            SliverToBoxAdapter(
              child: DateSectionHeader(
                dateLabel: monthYear,
                itemCount: monthFiles.length,
                isSelected: isGroupAllSelected,
                onSelectAll: (val) {
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
                },
              ),
            ),
          );

          // 2. Month photo grid
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

                    return PhotoGridTile(
                      file: file,
                      isSelected: isSelected,
                      isFavorite: file.isFavorite,
                      onTap: () {
                        if (widget.onTapTile != null) {
                          widget.onTapTile!(file);
                        } else {
                          SelectionService.instance.handleTap(file, widget.files);
                          ViewStateService.instance.setInfoMedia(file);
                        }
                      },
                      onSelect: () {
                        if (widget.onSelectTile != null) {
                          widget.onSelectTile!(file);
                        } else {
                          SelectionService.instance.toggle(file.id);
                        }
                      },
                      onToggleFavorite: () async {
                        if (widget.onToggleFavoriteTile != null) {
                          widget.onToggleFavoriteTile!(file);
                        } else {
                          await PhotosRepository().toggleFavorite(file.id);
                          await PhotosService.instance.refresh();
                        }
                      },
                      onOpenLightbox: () {
                        if (widget.onOpenLightboxTile != null) {
                          widget.onOpenLightboxTile!(file);
                        } else {
                          ViewStateService.instance.setLightboxMedia(file);
                        }
                      },
                      onOpenInfo: () {
                        if (widget.onOpenInfoTile != null) {
                          widget.onOpenInfoTile!(file);
                        } else {
                          ViewStateService.instance.setInfoMedia(file);
                          ViewStateService.instance.isInfoOpen.add(true);
                        }
                      },
                    );
                  },
                  childCount: monthFiles.length,
                ),
              ),
            ),
          );
        });

        return CustomScrollView(
          slivers: slivers,
        );
      },
    );
  }
}
