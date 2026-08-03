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
class PhotoGrid extends StatelessWidget {
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

  static int getColumnCount(double width) {
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    if (width < 1500) return 5;
    return 6;
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

    if (files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library,
              size: 64,
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
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

    final groups = _groupByMonthYear(files);

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = getColumnCount(constraints.maxWidth);

        final List<Widget> slivers = [];

        groups.forEach((monthYear, monthFiles) {
          final isGroupAllSelected = monthFiles.every(
            (f) => selectedIds.contains(f.id),
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
                      if (selectedIds.contains(f.id)) {
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
                    final isSelected = selectedIds.contains(file.id);

                    return PhotoGridTile(
                      file: file,
                      isSelected: isSelected,
                      isFavorite: file.isFavorite,
                      onTap: () {
                        if (onTapTile != null) {
                          onTapTile!(file);
                        } else {
                          ViewStateService.instance.setLightboxMedia(file);
                        }
                      },
                      onSelect: () {
                        if (onSelectTile != null) {
                          onSelectTile!(file);
                        } else {
                          SelectionService.instance.toggle(file.id);
                        }
                      },
                      onToggleFavorite: () async {
                        if (onToggleFavoriteTile != null) {
                          onToggleFavoriteTile!(file);
                        } else {
                          await PhotosRepository().toggleFavorite(file.id);
                          await PhotosService.instance.refresh();
                        }
                      },
                      onOpenLightbox: () {
                        if (onOpenLightboxTile != null) {
                          onOpenLightboxTile!(file);
                        } else {
                          ViewStateService.instance.setLightboxMedia(file);
                        }
                      },
                      onOpenInfo: () {
                        if (onOpenInfoTile != null) {
                          onOpenInfoTile!(file);
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
