import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/viewer/zoom_controller.dart';

class NextMediaIntent extends Intent {
  const NextMediaIntent();
}

class PreviousMediaIntent extends Intent {
  const PreviousMediaIntent();
}

class CloseViewerIntent extends Intent {
  const CloseViewerIntent();
}

class ToggleExifIntent extends Intent {
  const ToggleExifIntent();
}

class ZoomInIntent extends Intent {
  const ZoomInIntent();
}

class ZoomOutIntent extends Intent {
  const ZoomOutIntent();
}

/// Fullscreen image and video viewer modal overlay with zoom, slideshow,
/// EXIF overlay, and keyboard navigation support.
class FullscreenViewer extends StatefulWidget {
  final File currentFile;
  final List<File> mediaList;
  final VoidCallback onClose;
  final ValueChanged<File>? onToggleFavorite;
  final ValueChanged<File>? onOpenInfo;

  const FullscreenViewer({
    super.key,
    required this.currentFile,
    required this.mediaList,
    required this.onClose,
    this.onToggleFavorite,
    this.onOpenInfo,
  });

  @override
  State<FullscreenViewer> createState() => _FullscreenViewerState();
}

class _FullscreenViewerState extends State<FullscreenViewer> {
  late int _currentIndex;
  late ZoomController _zoomController;
  late TransformationController _transformationController;
  late FocusNode _focusNode;
  Timer? _slideshowTimer;
  bool _isSlideshowPlaying = false;
  bool _showExifOverlay = false;

  @override
  void initState() {
    super.initState();
    _updateCurrentIndex();
    _zoomController = ZoomController();
    _transformationController = TransformationController();
    _zoomController.addListener(_onZoomControllerChanged);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  void _updateCurrentIndex() {
    final idx = widget.mediaList.indexWhere((f) => f.id == widget.currentFile.id);
    _currentIndex = idx != -1 ? idx : 0;
  }

  @override
  void didUpdateWidget(covariant FullscreenViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentFile.id != widget.currentFile.id ||
        oldWidget.mediaList != widget.mediaList) {
      _updateCurrentIndex();
      _zoomController.reset();
    }
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _zoomController.removeListener(_onZoomControllerChanged);
    _zoomController.dispose();
    _transformationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onZoomControllerChanged() {
    _transformationController.value = Matrix4.identity()
      ..scale(_zoomController.zoomLevel);
  }

  File get _currentMedia {
    if (widget.mediaList.isEmpty) return widget.currentFile;
    final clampedIdx = _currentIndex.clamp(0, widget.mediaList.length - 1);
    return widget.mediaList[clampedIdx];
  }

  void _nextMedia() {
    if (widget.mediaList.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % widget.mediaList.length;
      _zoomController.reset();
    });
    final next = _currentMedia;
    ViewStateService.instance.setInfoMedia(next);
    SelectionService.instance.selectSingle(next.id);
  }

  void _prevMedia() {
    if (widget.mediaList.isEmpty) return;
    setState(() {
      _currentIndex =
          (_currentIndex - 1 + widget.mediaList.length) % widget.mediaList.length;
      _zoomController.reset();
    });
    final prev = _currentMedia;
    ViewStateService.instance.setInfoMedia(prev);
    SelectionService.instance.selectSingle(prev.id);
  }

  void _toggleSlideshow() {
    setState(() {
      _isSlideshowPlaying = !_isSlideshowPlaying;
      if (_isSlideshowPlaying) {
        _slideshowTimer = Timer.periodic(
          const Duration(milliseconds: 3500),
          (_) => _nextMedia(),
        );
      } else {
        _slideshowTimer?.cancel();
        _slideshowTimer = null;
      }
    });
  }

  void _toggleExifOverlay() {
    setState(() {
      _showExifOverlay = !_showExifOverlay;
    });
  }

  ImageProvider _buildImageProvider(File file) {
    final candidates = [
      if (file.localPath != null && file.localPath!.isNotEmpty) file.localPath!,
      if (file.path.isNotEmpty) file.path,
    ];

    for (final p in candidates) {
      if (io.File(p).existsSync()) {
        return FileImage(io.File(p));
      }
      if (p.startsWith('http://') || p.startsWith('https://')) {
        return NetworkImage(p);
      }
    }

    if (file.downloadUrl != null && file.downloadUrl!.isNotEmpty) {
      return NetworkImage(file.downloadUrl!);
    }

    final thumbProvider = ThumbnailResolver.providerFor(file.thumbnail);
    if (thumbProvider != null) {
      return thumbProvider;
    }

    final fallbackPath = file.localPath ?? file.path;
    if (fallbackPath.isNotEmpty) {
      return FileImage(io.File(fallbackPath));
    }

    return NetworkImage(file.downloadUrl ?? '');
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = _currentMedia;
    final isVideo = media.contentType.toLowerCase().startsWith('video/');

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.arrowRight): const NextMediaIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): const PreviousMediaIntent(),
        const SingleActivator(LogicalKeyboardKey.escape): const CloseViewerIntent(),
        const SingleActivator(LogicalKeyboardKey.keyI): const ToggleExifIntent(),
        const SingleActivator(LogicalKeyboardKey.equal): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.add): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.minus): const ZoomOutIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadAdd): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract): const ZoomOutIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          NextMediaIntent: CallbackAction<NextMediaIntent>(
            onInvoke: (_) => _nextMedia(),
          ),
          PreviousMediaIntent: CallbackAction<PreviousMediaIntent>(
            onInvoke: (_) => _prevMedia(),
          ),
          CloseViewerIntent: CallbackAction<CloseViewerIntent>(
            onInvoke: (_) {
              widget.onClose();
              return null;
            },
          ),
          ToggleExifIntent: CallbackAction<ToggleExifIntent>(
            onInvoke: (_) => _toggleExifOverlay(),
          ),
          ZoomInIntent: CallbackAction<ZoomInIntent>(
            onInvoke: (_) => _zoomController.zoomIn(),
          ),
          ZoomOutIntent: CallbackAction<ZoomOutIntent>(
            onInvoke: (_) => _zoomController.zoomOut(),
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black.withValues(alpha: 0.95),
            body: Stack(
              children: [
                // Center Media Content
                Center(
                  child: isVideo
                      ? _buildVideoPlaceholder(theme, media)
                      : InteractiveViewer(
                          transformationController: _transformationController,
                          minScale: ZoomController.minZoom,
                          maxScale: ZoomController.maxZoom,
                          child: Image(
                            image: _buildImageProvider(media),
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.broken_image,
                                      size: 64,
                                      color: theme.colorScheme.error,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      media.name,
                                      style: theme.textTheme.bodyMedium?.copyWith(
                                        color: theme.colorScheme.onSurface,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),

                // Top Navigation Bar
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    color: Colors.black.withValues(alpha: 0.6),
                    child: Row(
                      children: [
                        // Counter
                        Text(
                          '${_currentIndex + 1} / ${widget.mediaList.length}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        const Spacer(),

                        // Slideshow toggle
                        IconButton(
                          icon: Icon(
                            _isSlideshowPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: _isSlideshowPlaying
                              ? 'Pause Slideshow'
                              : 'Start Slideshow',
                          onPressed: _toggleSlideshow,
                        ),

                        // Zoom controls
                        IconButton(
                          icon: Icon(
                            Icons.remove,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Zoom Out',
                          onPressed: _zoomController.zoomOut,
                        ),
                        TextButton(
                          onPressed: _zoomController.reset,
                          child: Text(
                            '${(_zoomController.zoomLevel * 100).round()}%',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.add,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Zoom In',
                          onPressed: _zoomController.zoomIn,
                        ),

                        // Info overlay toggle
                        IconButton(
                          icon: Icon(
                            _showExifOverlay ? Icons.info : Icons.info_outline,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Toggle EXIF Info',
                          onPressed: () {
                            _toggleExifOverlay();
                            widget.onOpenInfo?.call(media);
                          },
                        ),

                        // Favorite toggle
                        IconButton(
                          icon: Icon(
                            media.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: media.isFavorite
                                ? Colors.red
                                : theme.colorScheme.onSurface,
                          ),
                          tooltip: media.isFavorite
                              ? 'Remove from favorites'
                              : 'Favorite',
                          onPressed: () =>
                              widget.onToggleFavorite?.call(media),
                        ),

                        // Download button
                        IconButton(
                          icon: Icon(
                            Icons.download,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Download',
                          onPressed: () {},
                        ),

                        // Close button
                        IconButton(
                          icon: Icon(
                            Icons.close,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Close',
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                ),

                // Side Navigation Controls
                if (widget.mediaList.length > 1) ...[
                  Positioned(
                    left: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: Icon(
                          Icons.chevron_left,
                          size: 36,
                          color: theme.colorScheme.onSurface,
                        ),
                        tooltip: 'Previous',
                        onPressed: _prevMedia,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: Icon(
                          Icons.chevron_right,
                          size: 36,
                          color: theme.colorScheme.onSurface,
                        ),
                        tooltip: 'Next',
                        onPressed: _nextMedia,
                      ),
                    ),
                  ),
                ],

                // Bottom EXIF Overlay
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: AnimatedOpacity(
                    opacity: _showExifOverlay ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_showExifOverlay,
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest
                              .withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: theme.colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              media.name,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 16,
                              runSpacing: 8,
                              children: [
                                _buildExifItem(
                                  theme,
                                  Icons.category_outlined,
                                  media.contentType,
                                ),
                                _buildExifItem(
                                  theme,
                                  Icons.data_usage_outlined,
                                  _formatFileSize(media.size),
                                ),
                                _buildExifItem(
                                  theme,
                                  Icons.calendar_today_outlined,
                                  media.dateCreated
                                      .toString()
                                      .split('.')
                                      .first,
                                ),
                                if (media.latitude != null &&
                                    media.longitude != null)
                                  _buildExifItem(
                                    theme,
                                    Icons.location_on_outlined,
                                    '${media.latitude!.toStringAsFixed(4)}, ${media.longitude!.toStringAsFixed(4)}',
                                  ),
                              ],
                            ),
                          ],
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
    );
  }

  Widget _buildVideoPlaceholder(ThemeData theme, File media) {
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.play_circle_outline,
            size: 72,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            media.name,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Video File (${_formatFileSize(media.size)})',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExifItem(ThemeData theme, IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
