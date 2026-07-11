import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/models/tables/folder.dart';
import 'package:mydatastudio/models/tables/file_asset.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:path/path.dart' as p;
import 'package:mydatastudio/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/modules/files/widgets/video_file_preview.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_metadata_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/folder_metadata_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/tabbed_metadata_section.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/image_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/thumbnail_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_type_icon_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pdf_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/stl_preview_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/text_preview_widget.dart';

class FileDetailsDrawer extends StatefulWidget {
  const FileDetailsDrawer({
    super.key,
    required this.asset,
    required this.collection,
    required this.width,
    required this.onClose,
    this.onExpand,
    this.onNavigateToFile,
    this.onDeleteFile,
  });

  final FileAsset asset;
  final Collection collection;
  final double width;
  final VoidCallback onClose;
  final VoidCallback? onExpand;
  final void Function(File)? onNavigateToFile;
  final void Function(File)? onDeleteFile;

  @override
  State<FileDetailsDrawer> createState() => _FileDetailsDrawerState();
}

class _FileDetailsDrawerState extends State<FileDetailsDrawer> {
  Map<String, IfdTag>? _exifData;
  bool _loadingExif = false;
  String? _resolution;

  @override
  void initState() {
    super.initState();
    _loadExif();
    _loadResolution();
  }

  @override
  void didUpdateWidget(FileDetailsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.path != widget.asset.path) {
      _exifData = null;
      _resolution = null;
      _loadExif();
      _loadResolution();
    }
  }

  /// Returns the absolute filesystem path for [file].
  String _resolvedPath(File file) =>
      FilePathResolver.absolute(file, widget.collection);

  Future<void> _loadExif() async {
    if (widget.asset is! File) return;
    final file = widget.asset as File;
    if (!_isImage(file)) return;

    setState(() => _loadingExif = true);
    try {
      final ioFile = io.File(_resolvedPath(file));
      if (await ioFile.exists()) {
        final exif = await readExifFromFile(ioFile);
        if (mounted) {
          setState(() {
            _exifData = exif;
            if (_resolution == null) {
              final widthTag = exif['EXIF ExifImageWidth'] ?? exif['Image ImageWidth'];
              final heightTag = exif['EXIF ExifImageLength'] ?? exif['Image ImageLength'];
              if (widthTag != null && heightTag != null) {
                final w = widthTag.printable.trim();
                final h = heightTag.printable.trim();
                if (w.isNotEmpty && h.isNotEmpty) {
                  _resolution = '${w}x${h}';
                }
              }
            }
          });
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loadingExif = false);
  }

  Future<void> _loadResolution() async {
    if (widget.asset is! File) return;
    final file = widget.asset as File;
    if (!_isImage(file)) return;

    final resolved = _resolvedPath(file);
    if (resolved.startsWith('gdrive://')) {
      return;
    }

    try {
      final ioFile = io.File(resolved);
      if (await ioFile.exists()) {
        final completer = Completer<Size>();
        final provider = FileImage(ioFile);
        final stream = provider.resolve(const ImageConfiguration());
        late ImageStreamListener listener;
        listener = ImageStreamListener(
          (ImageInfo info, bool _) {
            if (!completer.isCompleted) {
              completer.complete(Size(
                info.image.width.toDouble(),
                info.image.height.toDouble(),
              ));
            }
          },
          onError: (exception, stackTrace) {
            if (!completer.isCompleted) {
              completer.completeError(exception, stackTrace);
            }
          },
        );
        stream.addListener(listener);

        try {
          final size = await completer.future.timeout(
            const Duration(seconds: 3),
          );
          if (mounted) {
            setState(() {
              _resolution = '${size.width.toInt()}x${size.height.toInt()}';
            });
          }
        } finally {
          stream.removeListener(listener);
        }
      }
    } catch (e) {
      debugPrint('Error getting image resolution: $e');
    }
  }

  Future<List<int>?> _getGDriveFileBytes(File file) async {
    try {
      final collection = await CollectionRepository().collectionById(
        file.collectionId,
      );
      if (collection == null) return null;
      final token = await GoogleDriveAuthService.getValidAccessToken(
        collection,
      );

      Uri uri;
      if (file.path.startsWith('gdrive://')) {
        final fileId = file.path.replaceFirst('gdrive://', '');
        uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
        );
      } else if (file.downloadUrl != null) {
        uri = Uri.parse(file.downloadUrl!);
        final queryParams = Map<String, String>.from(uri.queryParameters);
        queryParams.remove('authuser');
        uri = uri.replace(queryParameters: queryParams);
      } else {
        return null;
      }

      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
    } catch (e) {
      debugPrint('Error downloading GDrive file for preview: $e');
    }
    return null;
  }

  Future<void> _saveContent(File file, String content) async {
    try {
      final ioFile = io.File(_resolvedPath(file));
      await ioFile.writeAsString(content);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File saved successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving file: $e')));
      }
    }
  }

  double get _previewHeight => (widget.width / 1.5).clamp(200.0, 500.0);

  Widget _previewContainer({required Widget child, Color? background}) {
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

  @override
  Widget build(BuildContext context) {
    final isImage = widget.asset is File && _isImage(widget.asset as File);
    final tabCount = isImage ? 3 : 1;

    return Container(
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── Header ─────────────────────────────────────────
          Container(
            padding: const EdgeInsets.only(
              left: 12,
              right: 4,
              top: 4,
              bottom: 4,
            ),
            decoration: const BoxDecoration(color: Colors.transparent),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 16),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    'File Details',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                ),
                if (widget.onExpand != null)
                  IconButton(
                    icon: Icon(
                      widget.width >= 700.0
                          ? Icons.close_fullscreen
                          : Icons.open_in_full,
                      size: 16,
                    ),
                    tooltip:
                        widget.width >= 700.0
                            ? 'Restore Width'
                            : 'Maximize Width',
                    onPressed: widget.onExpand,
                    padding: const EdgeInsets.all(4),
                    constraints: const BoxConstraints(),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Close',
                  onPressed: widget.onClose,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),

          // ─── Scrollable content ──────────────────────────────
          Expanded(
            child: DefaultTabController(
              length: tabCount,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPreviewSection(),
                    const SizedBox(height: 16),
                    if (widget.asset is File) ...[
                      FileMetadataSection(
                        file: widget.asset as File,
                        resolution: _resolution,
                      ),
                      const SizedBox(height: 16),
                      TabbedMetadataSection(
                        file: widget.asset as File,
                        collection: widget.collection,
                        exifData: _exifData,
                        isLoadingExif: _loadingExif,
                        showExif: isImage,
                        onNavigateToFile: widget.onNavigateToFile,
                        onDeleteFile: widget.onDeleteFile,
                      ),
                    ] else ...[
                      FolderMetadataSection(
                        name: widget.asset.name,
                        path: widget.asset.path,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewSection() {
    final asset = widget.asset;

    if (asset is File) {
      final ext = p.extension(asset.name).toLowerCase();
      const textExts = [
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
      ];

      if (_isPdf(asset)) {
        return PdfPreviewWidget(
          filePath:
              asset.path.startsWith('gdrive://')
                  ? asset.path
                  : _resolvedPath(asset),
          previewHeight: _previewHeight,
        );
      } else if (ext == '.stl') {
        return StlPreviewWidget(
          file: asset,
          previewHeight: _previewHeight,
          resolvedPath: _resolvedPath(asset),
          onDownloadGDrive:
              asset.path.startsWith('gdrive://')
                  ? () => _getGDriveFileBytes(asset)
                  : null,
        );
      } else if (asset.contentType.startsWith('video/') ||
          ['.mp4', '.mov', '.avi', '.mkv', '.m4v', '.webm'].contains(ext)) {
        return _previewContainer(
          background: Colors.grey.shade900,
          child: VideoFilePreview(
            path: _resolvedPath(asset),
            height: _previewHeight,
            isGDrive: asset.path.startsWith('gdrive://'),
            onDownloadGDrive: () => _getGDriveFileBytes(asset),
          ),
        );
      } else if (textExts.contains(ext) ||
          asset.contentType.startsWith('text/')) {
        return _buildTextPreview(asset, ext);
      } else if (_isImage(asset) || asset.path.startsWith('gdrive://')) {
        return _previewContainer(
          child: ImagePreviewWidget(
            file: asset,
            resolvedPath: _resolvedPath(asset),
          ),
        );
      } else {
        return _previewContainer(
          child: FileTypeIconWidget(
            contentType: asset.contentType,
            fileName: asset.name,
            isPdf: _isPdf(asset),
          ),
        );
      }
    } else if (asset is Folder) {
      final child =
          asset.thumbnail != null
              ? ThumbnailWidget(thumbnail: asset.thumbnail!)
              : const Center(
                child: Icon(Icons.folder, size: 80, color: Colors.amber),
              );
      return _previewContainer(child: child);
    }

    return _previewContainer(
      child: const Center(
        child: Icon(Icons.folder, size: 80, color: Colors.amber),
      ),
    );
  }

  Widget _buildTextPreview(File file, String ext) {
    return _TextPreviewLoader(
      file: file,
      ext: ext,
      previewHeight: _previewHeight,
      resolvedPath: _resolvedPath(file),
      onGetGDriveBytes: () => _getGDriveFileBytes(file),
      onSave: (content) => _saveContent(file, content),
    );
  }

  bool _isImage(File file) {
    if (file.contentType == FilesConstants.mimeTypeImage) return true;
    if (file.contentType.startsWith('image/')) return true;
    final ext = p.extension(file.name).toLowerCase();
    return [
      '.jpg',
      '.jpeg',
      '.png',
      '.gif',
      '.webp',
      '.bmp',
      '.tif',
      '.psd',
    ].contains(ext);
  }

  bool _isPdf(File file) {
    if (file.contentType == FilesConstants.mimeTypePdf) return true;
    if (file.contentType == 'application/x-pdf') return true;
    return p.extension(file.name).toLowerCase() == '.pdf';
  }
}

/// Loads text content then hands off to TextPreviewWidget.
/// Isolates async I/O from the parent so TextPreviewWidget stays purely
/// display-driven via `initialContent`.
class _TextPreviewLoader extends StatefulWidget {
  const _TextPreviewLoader({
    required this.file,
    required this.ext,
    required this.previewHeight,
    required this.resolvedPath,
    required this.onGetGDriveBytes,
    required this.onSave,
  });

  final File file;
  final String ext;
  final double previewHeight;
  final String resolvedPath;
  final Future<List<int>?> Function() onGetGDriveBytes;
  final Future<void> Function(String) onSave;

  @override
  State<_TextPreviewLoader> createState() => _TextPreviewLoaderState();
}

class _TextPreviewLoaderState extends State<_TextPreviewLoader> {
  String? _content;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_TextPreviewLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      setState(() {
        _content = null;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    try {
      if (widget.file.path.startsWith('gdrive://')) {
        final bytes = await widget.onGetGDriveBytes();
        if (bytes != null && mounted) {
          setState(() {
            _content = utf8.decode(bytes);
            _loading = false;
          });
          return;
        }
      } else {
        final ioFile = io.File(widget.resolvedPath);
        if (await ioFile.exists()) {
          final content = await ioFile.readAsString();
          if (mounted) {
            setState(() {
              _content = content;
              _loading = false;
            });
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading text content: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_content == null) {
      return FileTypeIconWidget(
        contentType: widget.file.contentType,
        fileName: widget.file.name,
      );
    }
    return TextPreviewWidget(
      file: widget.file,
      ext: widget.ext,
      previewHeight: widget.previewHeight,
      initialContent: _content,
      onSave: widget.onSave,
    );
  }
}
