import 'dart:io' as io;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
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
    final idx = widget.mediaList.indexWhere(
      (f) => f.id == widget.currentFile.id,
    );
    _currentIndex = idx != -1 ? idx : 0;
  }

  @override
  void didUpdateWidget(covariant FullscreenViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentFile.id != widget.currentFile.id ||
        oldWidget.mediaList != widget.mediaList) {
      _imageProviderCache.clear();
      _updateCurrentIndex();
      _zoomController.reset();
    }
  }

  @override
  void dispose() {
    _zoomController.removeListener(_onZoomControllerChanged);
    _zoomController.dispose();
    _transformationController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Size _viewportSize = Size.zero;

  void _onZoomControllerChanged() {
    final s = _zoomController.zoomLevel;
    final cx = _viewportSize.width > 0 ? _viewportSize.width / 2 : 0.0;
    final cy = _viewportSize.height > 0 ? _viewportSize.height / 2 : 0.0;

    setState(() {
      _transformationController.value =
          Matrix4.identity()
            ..translate(cx * (1 - s), cy * (1 - s))
            ..scale(s, s, 1.0);
    });
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
          (_currentIndex - 1 + widget.mediaList.length) %
          widget.mediaList.length;
      _zoomController.reset();
    });
    final prev = _currentMedia;
    ViewStateService.instance.setInfoMedia(prev);
    SelectionService.instance.selectSingle(prev.id);
  }

  final Map<String, ImageProvider> _imageProviderCache = {};

  ImageProvider _imageProviderFor(File file) {
    return _imageProviderCache.putIfAbsent(
      file.id,
      () => _buildImageProvider(file),
    );
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
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const NextMediaIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const PreviousMediaIntent(),
        const SingleActivator(LogicalKeyboardKey.escape):
            const CloseViewerIntent(),
        const SingleActivator(LogicalKeyboardKey.keyI):
            const ToggleExifIntent(),
        const SingleActivator(LogicalKeyboardKey.equal): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.equal, shift: true):
            const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.add): const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.minus): const ZoomOutIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadAdd):
            const ZoomInIntent(),
        const SingleActivator(LogicalKeyboardKey.numpadSubtract):
            const ZoomOutIntent(),
        const CharacterActivator('+'): const ZoomInIntent(),
        const CharacterActivator('='): const ZoomInIntent(),
        const CharacterActivator('-'): const ZoomOutIntent(),
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
            onInvoke: (_) {
              ViewStateService.instance.setInfoMedia(_currentMedia);
              ViewStateService.instance.toggleInfo();
              widget.onOpenInfo?.call(_currentMedia);
              return null;
            },
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
                  child:
                      isVideo
                          ? _buildVideoPlaceholder(theme, media)
                          : LayoutBuilder(
                            builder: (context, constraints) {
                              _viewportSize = Size(
                                constraints.maxWidth,
                                constraints.maxHeight,
                              );
                              return InteractiveViewer(
                                transformationController:
                                    _transformationController,
                                minScale: ZoomController.minZoom,
                                maxScale: ZoomController.maxZoom,
                                child: Image(
                                  image: _imageProviderFor(media),
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
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color:
                                                      theme
                                                          .colorScheme
                                                          .onErrorContainer,
                                                ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              );
                            },
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

                        // Info button (opens Info sidebar)
                        IconButton(
                          icon: Icon(
                            Icons.info_outline,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Info Details',
                          onPressed: () {
                            ViewStateService.instance.setInfoMedia(media);
                            ViewStateService.instance.toggleInfo();
                            widget.onOpenInfo?.call(media);
                          },
                        ),

                        // Favorite toggle
                        IconButton(
                          icon: Icon(
                            media.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color:
                                media.isFavorite
                                    ? Colors.red
                                    : theme.colorScheme.onSurface,
                          ),
                          tooltip:
                              media.isFavorite
                                  ? 'Remove from favorites'
                                  : 'Favorite',
                          onPressed: () => widget.onToggleFavorite?.call(media),
                        ),

                        // Download button
                        IconButton(
                          icon: Icon(
                            Icons.download,
                            color: theme.colorScheme.onSurface,
                          ),
                          tooltip: 'Download',
                          onPressed: () {
                            BatchActionService.instance.downloadSingle(media);
                          },
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
}
