import 'dart:async';
import 'dart:io' as io;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_metadata_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_type_icon_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/image_description_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/image_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pdf_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/tabbed_metadata_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/tags_and_landmarks_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/text_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/video_file_preview.dart';
import 'package:mydatastudio/modules/search/widgets/search_sidebar_header.dart';
import 'package:path/path.dart' as p;

final AppLogger _logger = AppLogger(null);

/// Search's own detail panel for a file or photo hit.
///
/// Search owns this rather than reusing the Files module's `FileDetailsDrawer`
/// or the Photos module's `InfoSidebar` because both of those are wired into
/// their module's state: the Photos sidebar reads and writes
/// `ViewStateService`/`SelectionService` singletons, so opening a photo from a
/// search result would silently move the Photos module's cursor and selection
/// underneath the user. This panel is driven entirely by its own arguments.
///
/// The leaf sections it composes ([FileMetadataSection], [TabbedMetadataSection]
/// and friends) are already shared across both modules — those are display
/// components with no module state, and re-implementing them would be the
/// duplication, not the reuse.
class SearchFileSidebar extends StatefulWidget {
  const SearchFileSidebar({
    super.key,
    required this.file,
    required this.collection,
    required this.width,
    required this.onClose,
    this.onToggleWidth,
    this.onOpenLightbox,
    this.isWide = false,
  });

  final File file;

  /// The collection [file] belongs to — needed to turn its stored relative
  /// path into something on disk. Search spans every collection, so this can
  /// differ from row to row.
  final Collection collection;

  final double width;
  final VoidCallback onClose;
  final VoidCallback? onToggleWidth;
  final VoidCallback? onOpenLightbox;
  final bool isWide;

  @override
  State<SearchFileSidebar> createState() => _SearchFileSidebarState();
}

class _SearchFileSidebarState extends State<SearchFileSidebar> {
  Map<String, IfdTag>? _exifData;
  bool _loadingExif = false;
  String? _resolution;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SearchFileSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.id != widget.file.id) {
      _exifData = null;
      _resolution = null;
      _load();
    }
  }

  void _load() {
    _loadExif();
    _loadResolution();
  }

  String get _resolvedPath =>
      FilePathResolver.absolute(widget.file, widget.collection);

  bool get _isImage => _isImageFile(widget.file);

  static bool _isImageFile(File file) {
    if (file.contentType == FilesConstants.mimeTypeImage) return true;
    if (file.contentType.startsWith('image/')) return true;
    const imageExts = [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tif',
      '.psd',
      '.heic',
      '.heif',
    ];
    return imageExts.contains(p.extension(file.name).toLowerCase());
  }

  bool get _isPdf {
    final file = widget.file;
    if (file.contentType == FilesConstants.mimeTypePdf) return true;
    if (file.contentType == 'application/x-pdf') return true;
    return p.extension(file.name).toLowerCase() == '.pdf';
  }

  /// Guards every async completion below. Arrow-key navigation in the lightbox
  /// swaps the file while EXIF is still being read, and a late result would
  /// otherwise attach one photo's metadata to a different photo.
  bool _stillCurrent(String fileId) => mounted && widget.file.id == fileId;

  Future<void> _loadExif() async {
    if (!_isImage) return;
    final fileId = widget.file.id;

    final ioFile = io.File(_resolvedPath);
    if (!await ioFile.exists()) return;
    if (!_stillCurrent(fileId)) return;

    setState(() => _loadingExif = true);
    try {
      final exif = await readExifFromFile(ioFile);
      if (_stillCurrent(fileId)) {
        setState(() {
          _exifData = exif;
          _resolution ??= _resolutionFromExif(exif);
        });
      }
    } catch (e) {
      _logger.w('SearchFileSidebar: could not read EXIF for $fileId: $e');
    }
    if (_stillCurrent(fileId)) setState(() => _loadingExif = false);
  }

  static String? _resolutionFromExif(Map<String, IfdTag> exif) {
    final widthTag = exif['EXIF ExifImageWidth'] ?? exif['Image ImageWidth'];
    final heightTag = exif['EXIF ExifImageLength'] ?? exif['Image ImageLength'];
    if (widthTag == null || heightTag == null) return null;
    final w = widthTag.printable.trim();
    final h = heightTag.printable.trim();
    if (w.isEmpty || h.isEmpty) return null;
    return '${w}x$h';
  }

  Future<void> _loadResolution() async {
    if (!_isImage) return;
    final fileId = widget.file.id;
    final resolved = _resolvedPath;
    // Only the local copy can be measured without downloading the original.
    if (resolved.startsWith('gdrive://')) return;

    try {
      final ioFile = io.File(resolved);
      if (!await ioFile.exists()) return;

      final completer = Completer<Size>();
      final stream = FileImage(ioFile).resolve(const ImageConfiguration());
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) {
            completer.complete(
              Size(info.image.width.toDouble(), info.image.height.toDouble()),
            );
          }
        },
        onError: (error, stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
        },
      );
      stream.addListener(listener);

      try {
        final size = await completer.future.timeout(const Duration(seconds: 3));
        if (_stillCurrent(fileId)) {
          setState(() {
            _resolution = '${size.width.toInt()}x${size.height.toInt()}';
          });
        }
      } finally {
        stream.removeListener(listener);
      }
    } catch (e) {
      _logger.w('SearchFileSidebar: could not size $fileId: $e');
    }
  }

  double get _previewHeight => (widget.width / 1.5).clamp(200.0, 500.0);

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final description = file.description?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchSidebarHeader(
          icon: Icons.insert_drive_file_outlined,
          title: 'File Details',
          isWide: widget.isWide,
          onToggleWidth: widget.onToggleWidth,
          onClose: widget.onClose,
        ),
        Expanded(
          child: DefaultTabController(
            length: _isImage ? 3 : 1,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPreview(),
                  const SizedBox(height: 16),
                  if (_isImage &&
                      description != null &&
                      description.isNotEmpty) ...[
                    ImageDescriptionSection(description: description),
                    const SizedBox(height: 16),
                  ],
                  FileMetadataSection(file: file, resolution: _resolution),
                  TagsAndLandmarksSection(fileId: file.id),
                  const SizedBox(height: 16),
                  TabbedMetadataSection(
                    file: file,
                    collection: widget.collection,
                    exifData: _exifData,
                    isLoadingExif: _loadingExif,
                    showExif: _isImage,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final file = widget.file;
    final resolved = _resolvedPath;
    final ext = p.extension(file.name).toLowerCase();

    if (_isPdf) {
      return PdfPreviewWidget(
        filePath: file.path.startsWith('gdrive://') ? file.path : resolved,
        previewHeight: _previewHeight,
      );
    }

    if (file.contentType.startsWith('video/') ||
        const ['.mp4', '.mov', '.avi', '.mkv', '.m4v', '.webm'].contains(ext)) {
      return _framed(
        background: Colors.grey.shade900,
        child: VideoFilePreview(path: resolved, height: _previewHeight),
      );
    }

    if (_isTextExtension(ext) || file.contentType.startsWith('text/')) {
      return _SearchTextPreview(
        file: file,
        ext: ext,
        resolvedPath: resolved,
        previewHeight: _previewHeight,
      );
    }

    if (_isImage || file.path.startsWith('gdrive://')) {
      // Tapping the preview is the mouse-driven route to the same viewer the
      // spacebar opens — the shortcut alone is not discoverable.
      return GestureDetector(
        onTap: widget.onOpenLightbox,
        child: _framed(
          child: ImagePreviewWidget(file: file, resolvedPath: resolved),
        ),
      );
    }

    return _framed(
      child: FileTypeIconWidget(
        contentType: file.contentType,
        fileName: file.name,
        isPdf: _isPdf,
      ),
    );
  }

  static bool _isTextExtension(String ext) => const [
    '.txt',
    '.html',
    '.xml',
    '.xsl',
    '.xslt',
    '.md',
    '.markdown',
    '.json',
    '.yaml',
    '.yml',
    '.dart',
    '.py',
    '.js',
    '.css',
  ].contains(ext);

  Widget _framed({required Widget child, Color? background}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: _previewHeight,
        width: double.infinity,
        color: background ?? Colors.transparent,
        child: child,
      ),
    );
  }
}

/// Reads a text file off disk and hands the contents to [TextPreviewWidget].
///
/// [TextPreviewWidget] can load a file itself, but only from `file.path` — and
/// a `File` straight out of the search index carries the path *relative* to its
/// collection, so letting it try would just render an empty preview. Passing
/// `initialContent` from the resolved absolute path is what makes it work.
///
/// Read-only: [TextPreviewWidget]'s save callback is wired to a no-op message
/// rather than a write. Search is a place to find things and confirm what they
/// are; editing a document belongs in the Files module, where the collection
/// context and the rest of the file tools are.
class _SearchTextPreview extends StatefulWidget {
  const _SearchTextPreview({
    required this.file,
    required this.ext,
    required this.resolvedPath,
    required this.previewHeight,
  });

  final File file;
  final String ext;
  final String resolvedPath;
  final double previewHeight;

  @override
  State<_SearchTextPreview> createState() => _SearchTextPreviewState();
}

class _SearchTextPreviewState extends State<_SearchTextPreview> {
  String? _content;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_SearchTextPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolvedPath != widget.resolvedPath) {
      setState(() {
        _content = null;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    final path = widget.resolvedPath;
    try {
      final ioFile = io.File(path);
      if (await ioFile.exists()) {
        final content = await ioFile.readAsString();
        if (mounted && widget.resolvedPath == path) {
          setState(() {
            _content = content;
            _loading = false;
          });
          return;
        }
      }
    } catch (e) {
      _logger.w('SearchFileSidebar: could not read text at $path: $e');
    }
    if (mounted && widget.resolvedPath == path) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        height: widget.previewHeight,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_content == null) {
      return SizedBox(
        height: widget.previewHeight,
        child: FileTypeIconWidget(
          contentType: widget.file.contentType,
          fileName: widget.file.name,
        ),
      );
    }
    return TextPreviewWidget(
      file: widget.file,
      ext: widget.ext,
      previewHeight: widget.previewHeight,
      initialContent: _content,
      onSave: (_) async {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Open this file in Files to edit and save it'),
          ),
        );
      },
    );
  }
}
