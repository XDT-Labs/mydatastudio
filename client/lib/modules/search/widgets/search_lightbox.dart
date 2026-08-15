import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';

/// Full-size viewer for a file hit, opened with the spacebar or a double-click.
///
/// A search-local rewrite of the Photos module's `FullscreenViewer` rather than
/// a reuse of it. That one pushes every navigation step into
/// `ViewStateService`/`SelectionService`, which are the Photos module's global
/// cursor — pressing the right arrow here would move the user's place in the
/// photo library, in a module they may not even have open. It also assumes it
/// holds the whole media list up front, which search cannot give it: results
/// arrive a page at a time and each one's absolute path needs its own
/// collection resolved. So stepping is delegated to the page via [onNext] /
/// [onPrevious], which advance the selection and hand a new file back down.
class SearchLightbox extends StatefulWidget {
  const SearchLightbox({
    super.key,
    required this.file,
    required this.collection,
    required this.onClose,
    this.onNext,
    this.onPrevious,
    this.position,
  });

  final File file;
  final Collection collection;
  final VoidCallback onClose;

  /// Null when this is the only file in the loaded results — the arrows and
  /// their keyboard shortcuts go away rather than wrapping onto the same image.
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;

  /// "3 of 41", when the page can say where in the results this sits.
  final String? position;

  @override
  State<SearchLightbox> createState() => _SearchLightboxState();
}

class _SearchLightboxState extends State<SearchLightbox> {
  final TransformationController _transformation = TransformationController();
  final FocusNode _focusNode = FocusNode();
  double _zoom = 1.0;

  static const _minZoom = 1.0;
  static const _maxZoom = 5.0;
  static const _zoomStep = 0.25;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void didUpdateWidget(SearchLightbox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id) _resetZoom();
  }

  @override
  void dispose() {
    _transformation.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _resetZoom() {
    setState(() {
      _zoom = 1.0;
      _transformation.value = Matrix4.identity();
    });
  }

  void _setZoom(double next) {
    final clamped = next.clamp(_minZoom, _maxZoom);
    setState(() {
      _zoom = clamped;
      _transformation.value =
          Matrix4.identity()..scaleByDouble(clamped, clamped, 1.0, 1.0);
    });
  }

  /// Prefers the original on disk and falls back to the cached thumbnail.
  ///
  /// The point of this view is judging whether a semantic hit is actually the
  /// thing that was searched for, so a 320px thumbnail stretched full screen is
  /// a poor substitute — but it beats a broken-image icon for a file whose
  /// local copy has gone missing.
  ImageProvider? _imageProvider() {
    final resolved = FilePathResolver.absolute(widget.file, widget.collection);
    if (!resolved.startsWith('gdrive://') && io.File(resolved).existsSync()) {
      return FileImage(io.File(resolved));
    }

    final localPath = widget.file.localPath;
    if (localPath != null &&
        localPath.isNotEmpty &&
        io.File(localPath).existsSync()) {
      return FileImage(io.File(localPath));
    }

    final downloadUrl = widget.file.downloadUrl;
    if (downloadUrl != null && downloadUrl.isNotEmpty) {
      return NetworkImage(downloadUrl);
    }

    return ThumbnailResolver.providerFor(widget.file.thumbnail);
  }

  Widget _unavailable(ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image, size: 64, color: theme.colorScheme.error),
        const SizedBox(height: 8),
        Text(
          widget.file.name,
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _CloseLightboxIntent(),
        const SingleActivator(LogicalKeyboardKey.space):
            const _CloseLightboxIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _NextFileIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _PreviousFileIntent(),
        const CharacterActivator('+'): const _ZoomInIntent(),
        const CharacterActivator('='): const _ZoomInIntent(),
        const CharacterActivator('-'): const _ZoomOutIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _CloseLightboxIntent: CallbackAction<_CloseLightboxIntent>(
            onInvoke: (_) {
              widget.onClose();
              return null;
            },
          ),
          _NextFileIntent: CallbackAction<_NextFileIntent>(
            onInvoke: (_) {
              widget.onNext?.call();
              return null;
            },
          ),
          _PreviousFileIntent: CallbackAction<_PreviousFileIntent>(
            onInvoke: (_) {
              widget.onPrevious?.call();
              return null;
            },
          ),
          _ZoomInIntent: CallbackAction<_ZoomInIntent>(
            onInvoke: (_) => _setZoom(_zoom + _zoomStep),
          ),
          _ZoomOutIntent: CallbackAction<_ZoomOutIntent>(
            onInvoke: (_) => _setZoom(_zoom - _zoomStep),
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Material(
            color: Colors.black.withValues(alpha: 0.95),
            child: Stack(
              children: [
                Center(
                  child: Builder(
                    builder: (context) {
                      final provider = _imageProvider();
                      if (provider == null) return _unavailable(theme);
                      return InteractiveViewer(
                        transformationController: _transformation,
                        minScale: _minZoom,
                        maxScale: _maxZoom,
                        child: Image(
                          image: provider,
                          fit: BoxFit.contain,
                          errorBuilder:
                              (context, error, stack) => _unavailable(theme),
                        ),
                      );
                    },
                  ),
                ),
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
                        Expanded(
                          child: Text(
                            widget.position == null
                                ? widget.file.name
                                : '${widget.file.name}  ·  ${widget.position}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.remove, color: Colors.white),
                          tooltip: 'Zoom Out',
                          onPressed: () => _setZoom(_zoom - _zoomStep),
                        ),
                        TextButton(
                          onPressed: _resetZoom,
                          child: Text(
                            '${(_zoom * 100).round()}%',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add, color: Colors.white),
                          tooltip: 'Zoom In',
                          onPressed: () => _setZoom(_zoom + _zoomStep),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          tooltip: 'Close',
                          onPressed: widget.onClose,
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.onPrevious != null)
                  Positioned(
                    left: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: const Icon(
                          Icons.chevron_left,
                          size: 36,
                          color: Colors.white,
                        ),
                        tooltip: 'Previous',
                        onPressed: widget.onPrevious,
                      ),
                    ),
                  ),
                if (widget.onNext != null)
                  Positioned(
                    right: 16,
                    top: 0,
                    bottom: 0,
                    child: Center(
                      child: IconButton(
                        icon: const Icon(
                          Icons.chevron_right,
                          size: 36,
                          color: Colors.white,
                        ),
                        tooltip: 'Next',
                        onPressed: widget.onNext,
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
}

class _CloseLightboxIntent extends Intent {
  const _CloseLightboxIntent();
}

class _NextFileIntent extends Intent {
  const _NextFileIntent();
}

class _PreviousFileIntent extends Intent {
  const _PreviousFileIntent();
}

class _ZoomInIntent extends Intent {
  const _ZoomInIntent();
}

class _ZoomOutIntent extends Intent {
  const _ZoomOutIntent();
}
