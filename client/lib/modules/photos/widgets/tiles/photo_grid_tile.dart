import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';

Widget buildWiredPhotoGridTile({
  required File file,
  required bool isSelected,
  required List<File> allFiles,
  ValueChanged<File>? onTapTile,
  ValueChanged<File>? onSelectTile,
  ValueChanged<File>? onToggleFavoriteTile,
  ValueChanged<File>? onOpenLightboxTile,
  ValueChanged<File>? onOpenInfoTile,
}) {
  return PhotoGridTile(
    file: file,
    isSelected: isSelected,
    isFavorite: file.isFavorite,
    onTap: () {
      if (onTapTile != null) {
        onTapTile(file);
      } else {
        SelectionService.instance.handleTap(file, allFiles);
        ViewStateService.instance.setInfoMedia(file);
      }
    },
    onSelect: () {
      if (onSelectTile != null) {
        onSelectTile(file);
      } else {
        SelectionService.instance.toggle(file.id);
      }
    },
    onToggleFavorite: () async {
      if (onToggleFavoriteTile != null) {
        onToggleFavoriteTile(file);
      } else {
        await PhotosRepository().toggleFavorite(file.id);
        await PhotosService.instance.refresh();
      }
    },
    onOpenLightbox: () {
      if (onOpenLightboxTile != null) {
        onOpenLightboxTile(file);
      } else {
        ViewStateService.instance.setLightboxMedia(file);
      }
    },
    onOpenInfo: () {
      if (onOpenInfoTile != null) {
        onOpenInfoTile(file);
      } else {
        ViewStateService.instance.setInfoMedia(file);
        ViewStateService.instance.isInfoOpen.add(true);
      }
    },
  );
}

/// Individual grid cell widget representing a photo or video item in the photo grid.
class PhotoGridTile extends StatefulWidget {
  const PhotoGridTile({
    super.key,
    required this.file,
    required this.isSelected,
    required this.onTap,
    required this.onSelect,
    required this.onToggleFavorite,
    required this.onOpenLightbox,
    required this.onOpenInfo,
    this.isFavorite = false,
  });

  final File file;
  final bool isSelected;
  final bool isFavorite;
  final VoidCallback onTap;
  final VoidCallback onSelect;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenLightbox;
  final VoidCallback onOpenInfo;

  @override
  State<PhotoGridTile> createState() => _PhotoGridTileState();
}

class _PhotoGridTileState extends State<PhotoGridTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isVideo = widget.file.contentType.startsWith('video/');
    final hasLocation =
        widget.file.latitude != null && widget.file.longitude != null;

    final imageProvider = ThumbnailResolver.providerFor(widget.file.thumbnail);
    final isFav = widget.isFavorite || widget.file.isFavorite;
    final showOverlay = _isHovered || widget.isSelected;

    return Focus(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: AspectRatio(
          aspectRatio: 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color:
                    widget.isSelected
                        ? colorScheme.primary
                        : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Base Image / Thumbnail (tappable area)
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: widget.onTap,
                      onDoubleTap: widget.onOpenLightbox,
                      onSecondaryTap: widget.onOpenInfo,
                      behavior: HitTestBehavior.opaque,
                      child:
                          imageProvider != null
                              ? Image(
                                image: imageProvider,
                                fit: BoxFit.cover,
                                frameBuilder: (
                                  context,
                                  child,
                                  frame,
                                  wasSynchronouslyLoaded,
                                ) {
                                  if (wasSynchronouslyLoaded) return child;
                                  return AnimatedOpacity(
                                    opacity: frame == null ? 0 : 1,
                                    duration: const Duration(milliseconds: 200),
                                    child: child,
                                  );
                                },
                                errorBuilder:
                                    (context, error, stackTrace) =>
                                        _buildFallback(colorScheme, isVideo),
                              )
                              : _buildFallback(colorScheme, isVideo),
                    ),
                  ),

                  // Selected semi-transparent overlay
                  if (widget.isSelected)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Container(
                          color: colorScheme.primary.withValues(alpha: 0.2),
                        ),
                      ),
                    ),

                  // Persistent Favorite Badge (when not hovering and favorited)
                  if (isFav && !showOverlay)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.favorite,
                            color: Colors.red,
                            size: 14,
                          ),
                        ),
                      ),
                    ),

                  // Hover / Selection Overlay Controls
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: showOverlay ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: IgnorePointer(
                        ignoring: !showOverlay,
                        child: GestureDetector(
                          onTap: widget.onTap,
                          onDoubleTap: widget.onOpenLightbox,
                          onSecondaryTap: widget.onOpenInfo,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.5),
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.6),
                                ],
                                stops: const [0.0, 0.5, 1.0],
                              ),
                            ),
                            child: Stack(
                              children: [
                                // Top-left: Selection checkbox
                                Positioned(
                                  top: 4,
                                  left: 4,
                                  child: IconButton(
                                    icon: Icon(
                                      widget.isSelected
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                      color:
                                          widget.isSelected
                                              ? colorScheme.primary
                                              : Colors.white70,
                                    ),
                                    onPressed: widget.onSelect,
                                    tooltip:
                                        widget.isSelected
                                            ? 'Deselect'
                                            : 'Select',
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                  ),
                                ),

                                // Top-right: Favorite heart toggle
                                Positioned(
                                  top: 4,
                                  right: 4,
                                  child: IconButton(
                                    icon: Icon(
                                      isFav
                                          ? Icons.favorite
                                          : Icons.favorite_border,
                                      color:
                                          isFav ? Colors.red : Colors.white70,
                                    ),
                                    onPressed: widget.onToggleFavorite,
                                    tooltip:
                                        isFav
                                            ? 'Remove from favorites'
                                            : 'Favorite',
                                    constraints: const BoxConstraints(),
                                    padding: const EdgeInsets.all(4),
                                  ),
                                ),

                                // Bottom-left: Video duration / Location badges
                                Positioned(
                                  bottom: 6,
                                  left: 6,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isVideo)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.7,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.play_arrow,
                                                size: 14,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                '0:32',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: Colors.white,
                                                      fontSize: 10,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      if (isVideo && hasLocation)
                                        const SizedBox(width: 4),
                                      if (hasLocation)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.black.withValues(
                                              alpha: 0.7,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Icon(
                                                Icons.location_on,
                                                size: 14,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 2),
                                              Text(
                                                'Location',
                                                style: theme
                                                    .textTheme
                                                    .labelSmall
                                                    ?.copyWith(
                                                      color: Colors.white,
                                                      fontSize: 10,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),

                                // Bottom-right: Info icon button & Expand icon button
                                Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        icon: const Icon(
                                          Icons.info_outline,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        onPressed: widget.onOpenInfo,
                                        tooltip: 'Info Details',
                                        constraints: const BoxConstraints(),
                                        padding: const EdgeInsets.all(4),
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        icon: const Icon(
                                          Icons.open_in_full,
                                          color: Colors.white70,
                                          size: 18,
                                        ),
                                        onPressed: widget.onOpenLightbox,
                                        tooltip: 'Expand',
                                        constraints: const BoxConstraints(),
                                        padding: const EdgeInsets.all(4),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFallback(ColorScheme colorScheme, bool isVideo) {
    return Container(
      color: colorScheme.surfaceContainerHigh,
      child: Center(
        child: Icon(
          isVideo ? Icons.movie_outlined : Icons.photo_outlined,
          color: colorScheme.onSurfaceVariant,
          size: 32,
        ),
      ),
    );
  }
}
