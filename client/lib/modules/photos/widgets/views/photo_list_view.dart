import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/utils/byte_formatter.dart';

/// Tabular list view of photos with metadata columns and virtualization.
class PhotoListView extends StatefulWidget {
  const PhotoListView({
    super.key,
    required this.files,
    required this.selectedIds,
    this.onTapRow,
    this.onDoubleTapRow,
    this.onSelectRow,
    this.onToggleFavoriteRow,
    this.onOpenLightboxRow,
    this.onOpenInfoRow,
    this.onDownloadRow,
  });

  final List<File> files;
  final Set<String> selectedIds;
  final ValueChanged<File>? onTapRow;
  final ValueChanged<File>? onDoubleTapRow;
  final ValueChanged<File>? onSelectRow;
  final ValueChanged<File>? onToggleFavoriteRow;
  final ValueChanged<File>? onOpenLightboxRow;
  final ValueChanged<File>? onOpenInfoRow;
  final ValueChanged<File>? onDownloadRow;

  @override
  State<PhotoListView> createState() => _PhotoListViewState();
}

class _PhotoListViewState extends State<PhotoListView> {
  StreamSubscription<PhotoFilter>? _filterSub;
  PhotoFilter _currentFilter = const PhotoFilter();

  @override
  void initState() {
    super.initState();
    _currentFilter = ViewStateService.instance.activeFilter.value;
    _filterSub = ViewStateService.instance.activeFilter.listen((filter) {
      if (mounted) {
        setState(() {
          _currentFilter = filter;
        });
      }
    });
  }

  @override
  void dispose() {
    _filterSub?.cancel();
    super.dispose();
  }

  void _onSortHeaderTapped(PhotoSortOrder targetSort) {
    PhotoSortOrder newSort = targetSort;
    if (targetSort == PhotoSortOrder.dateDesc || targetSort == PhotoSortOrder.dateAsc) {
      if (_currentFilter.sortBy == PhotoSortOrder.dateDesc) {
        newSort = PhotoSortOrder.dateAsc;
      } else {
        newSort = PhotoSortOrder.dateDesc;
      }
    } else {
      newSort = targetSort;
    }
    ViewStateService.instance.setSortOrder(newSort);
  }

  Widget _buildSortIndicator(PhotoSortOrder sortKey) {
    if (sortKey == PhotoSortOrder.dateDesc || sortKey == PhotoSortOrder.dateAsc) {
      if (_currentFilter.sortBy == PhotoSortOrder.dateDesc) {
        return const Padding(
          padding: EdgeInsets.only(left: 4.0),
          child: Icon(Icons.arrow_downward, size: 14),
        );
      } else if (_currentFilter.sortBy == PhotoSortOrder.dateAsc) {
        return const Padding(
          padding: EdgeInsets.only(left: 4.0),
          child: Icon(Icons.arrow_upward, size: 14),
        );
      }
    } else if (_currentFilter.sortBy == sortKey) {
      return const Padding(
        padding: EdgeInsets.only(left: 4.0),
        child: Icon(Icons.arrow_upward, size: 14),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (widget.files.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library,
              size: 64,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No photos found',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    final headerStyle = GoogleFonts.inter(
      textStyle: theme.textTheme.labelSmall,
      fontWeight: FontWeight.w600,
      color: colorScheme.onSurfaceVariant,
    );

    return Column(
      children: [
        // Fixed Header Row
        Container(
          height: 40,
          color: colorScheme.surfaceContainerLow,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Column 1: Thumbnail + Title
              Expanded(
                flex: 3,
                child: InkWell(
                  onTap: () => _onSortHeaderTapped(PhotoSortOrder.title),
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Thumbnail + Title',
                          style: headerStyle,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      _buildSortIndicator(PhotoSortOrder.title),
                    ],
                  ),
                ),
              ),
              // Column 2: Date
              SizedBox(
                width: 140,
                child: InkWell(
                  onTap: () => _onSortHeaderTapped(PhotoSortOrder.dateDesc),
                  child: Row(
                    children: [
                      Text('Date', style: headerStyle),
                      _buildSortIndicator(PhotoSortOrder.dateDesc),
                    ],
                  ),
                ),
              ),
              // Column 3: Location
              SizedBox(
                width: 160,
                child: Text('Location', style: headerStyle),
              ),
              // Column 4: Camera / Details
              SizedBox(
                width: 200,
                child: InkWell(
                  onTap: () => _onSortHeaderTapped(PhotoSortOrder.size),
                  child: Row(
                    children: [
                      Text('Camera / Details', style: headerStyle),
                      _buildSortIndicator(PhotoSortOrder.size),
                    ],
                  ),
                ),
              ),
              // Column 5: Actions
              SizedBox(
                width: 150,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text('Actions', style: headerStyle),
                ),
              ),
            ],
          ),
        ),

        // Virtualized Scrollable Rows
        Expanded(
          child: ListView.builder(
            itemCount: widget.files.length,
            itemBuilder: (context, index) {
              final file = widget.files[index];
              final isSelected = widget.selectedIds.contains(file.id);

              return _PhotoListRowTile(
                key: ValueKey(file.id),
                file: file,
                isSelected: isSelected,
                onTap: () {
                  if (widget.onTapRow != null) {
                    widget.onTapRow!(file);
                  } else {
                    SelectionService.instance.handleTap(file, widget.files);
                    ViewStateService.instance.setInfoMedia(file);
                  }
                },
                onDoubleTap: () {
                  if (widget.onDoubleTapRow != null) {
                    widget.onDoubleTapRow!(file);
                  } else {
                    ViewStateService.instance.openLightbox(file);
                  }
                },
                onSelect: () {
                  if (widget.onSelectRow != null) {
                    widget.onSelectRow!(file);
                  } else {
                    SelectionService.instance.toggle(file.id);
                  }
                },
                onToggleFavorite: () async {
                  if (widget.onToggleFavoriteRow != null) {
                    widget.onToggleFavoriteRow!(file);
                  } else {
                    await PhotosRepository().toggleFavorite(file.id);
                    await PhotosService.instance.refresh();
                  }
                },
                onOpenLightbox: () {
                  if (widget.onOpenLightboxRow != null) {
                    widget.onOpenLightboxRow!(file);
                  } else {
                    ViewStateService.instance.openLightbox(file);
                  }
                },
                onOpenInfo: () {
                  if (widget.onOpenInfoRow != null) {
                    widget.onOpenInfoRow!(file);
                  } else {
                    ViewStateService.instance.openInfo(file);
                  }
                },
                onDownload: widget.onDownloadRow != null
                    ? () => widget.onDownloadRow!(file)
                    : () => BatchActionService.instance.downloadSingle(file),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PhotoListRowTile extends StatefulWidget {
  const _PhotoListRowTile({
    super.key,
    required this.file,
    required this.isSelected,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSelect,
    required this.onToggleFavorite,
    required this.onOpenLightbox,
    required this.onOpenInfo,
    this.onDownload,
  });

  final File file;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onSelect;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenLightbox;
  final VoidCallback onOpenInfo;
  final VoidCallback? onDownload;

  @override
  State<_PhotoListRowTile> createState() => _PhotoListRowTileState();
}

class _PhotoListRowTileState extends State<_PhotoListRowTile> {
  bool _isHovered = false;

  String _formatDate(DateTime date) {
    return DateFormat('MMM dd, yyyy').format(date);
  }

  String _formatLocation(double? lat, double? lng) {
    if (lat == null || lng == null) return 'Unknown';
    return '${lat.toStringAsFixed(2)}, ${lng.toStringAsFixed(2)}';
  }

  Widget _buildFallbackThumbnail(ColorScheme colorScheme, bool isVideo) {
    return Container(
      width: 40,
      height: 40,
      color: colorScheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          isVideo ? Icons.movie_outlined : Icons.photo_outlined,
          color: colorScheme.onSurfaceVariant,
          size: 20,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isVideo = widget.file.contentType.startsWith('video/');
    final imageProvider = ThumbnailResolver.providerFor(widget.file.thumbnail);

    final backgroundColor = widget.isSelected
        ? colorScheme.primaryContainer.withValues(alpha: 0.15)
        : (_isHovered ? colorScheme.surfaceContainerHigh : Colors.transparent);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        onDoubleTap: widget.onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border(
              left: BorderSide(
                color: widget.isSelected ? colorScheme.primary : Colors.transparent,
                width: 3,
              ),
              bottom: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              // Column 1 (flex: 3): Selection checkbox + 40x40 thumbnail + title + path subtext
              Expanded(
                flex: 3,
                child: Row(
                  children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: widget.isSelected,
                        activeColor: colorScheme.primary,
                        onChanged: (_) => widget.onSelect(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        width: 40,
                        height: 40,
                        child: imageProvider != null
                            ? Image(
                                image: imageProvider,
                                fit: BoxFit.cover,
                                errorBuilder: (ctx, err, stack) =>
                                    _buildFallbackThumbnail(colorScheme, isVideo),
                              )
                            : _buildFallbackThumbnail(colorScheme, isVideo),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            widget.file.name,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.file.path,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Column 2 (width: 140): Calendar icon + formatted date
              SizedBox(
                width: 140,
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _formatDate(widget.file.dateCreated),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              // Column 3 (width: 160): MapPin icon + Location
              SizedBox(
                width: 160,
                child: Row(
                  children: [
                    Icon(
                      Icons.location_on_outlined,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _formatLocation(
                          widget.file.latitude,
                          widget.file.longitude,
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              // Column 4 (width: 200): Details / Formatted file size
              SizedBox(
                width: 200,
                child: Text(
                  formatBytes(widget.file.size),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // Column 5 (width: 150): Actions (Favorite toggle, info, expand, download)
              SizedBox(
                width: 150,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: Icon(
                          widget.file.isFavorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: widget.file.isFavorite
                              ? colorScheme.error
                              : colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onToggleFavorite,
                        tooltip: widget.file.isFavorite
                            ? 'Remove favorite'
                            : 'Favorite',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        icon: Icon(
                          Icons.info_outline,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onOpenInfo,
                        tooltip: 'Info Details',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        icon: Icon(
                          Icons.open_in_full,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onOpenLightbox,
                        tooltip: 'Expand',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      ),
                      const SizedBox(width: 2),
                      IconButton(
                        icon: Icon(
                          Icons.download_outlined,
                          color: colorScheme.onSurfaceVariant,
                          size: 18,
                        ),
                        onPressed: widget.onDownload,
                        tooltip: 'Download',
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
