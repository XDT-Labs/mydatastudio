import 'dart:convert';
import 'dart:io' as io;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:moment_dart/moment_dart.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

class FileDetailsDrawer extends StatefulWidget {
  const FileDetailsDrawer({
    super.key,
    required this.asset,
    required this.width,
    required this.onClose,
  });

  final FileAsset asset;
  final double width;
  final VoidCallback onClose;

  @override
  State<FileDetailsDrawer> createState() => _FileDetailsDrawerState();
}

class _FileDetailsDrawerState extends State<FileDetailsDrawer> {
  Map<String, IfdTag>? _exifData;
  bool _loadingExif = false;

  PdfController? _pdfController;
  int _pdfCurrentPage = 1;
  int _pdfTotalPages = 0;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  @override
  void didUpdateWidget(FileDetailsDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.path != widget.asset.path) {
      _pdfController?.dispose();
      _pdfController = null;
      _pdfCurrentPage = 1;
      _pdfTotalPages = 0;
      _exifData = null;
      _loadMetadata();
    }
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    if (widget.asset is! File) return;
    final file = widget.asset as File;

    // EXIF for images
    if (file.contentType == FilesConstants.mimeTypeImage) {
      setState(() => _loadingExif = true);
      try {
        final ioFile = io.File(file.path);
        if (await ioFile.exists()) {
          final exif = await readExifFromFile(ioFile);
          if (mounted) setState(() => _exifData = exif);
        }
      } catch (_) {}
      if (mounted) setState(() => _loadingExif = false);
    }

    // PDF controller
    if (file.contentType == FilesConstants.mimeTypePdf) {
      try {
        final doc = await PdfDocument.openFile(file.path);
        final pages = doc.pagesCount;
        final controller = PdfController(document: Future.value(doc));
        if (mounted) {
          setState(() {
            _pdfController = controller;
            _pdfTotalPages = pages;
            _pdfCurrentPage = 1;
          });
        }
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          left: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ─── Header ─────────────────────────────────────────
          Container(
            padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200, width: 1),
              ),
            ),
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
              length: 3,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildPreviewSection(),
                    const SizedBox(height: 16),
                    if (widget.asset is File) ...[
                      _buildFileMetadataSection(widget.asset as File),
                      const SizedBox(height: 16),
                      // _buildExifSection(), // Moved to tabs
                      // const SizedBox(height: 16),
                      // _buildGpsSection(),  // Moved to tabs
                      _buildTabbedMetadataSection(),
                    ] else ...[
                      _buildFolderMetadataSection(),
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

  // ─── Preview ──────────────────────────────────────────────────
  Widget _buildPreviewSection() {
    final asset = widget.asset;
    Widget preview;

    if (asset is File) {
      if (asset.contentType == FilesConstants.mimeTypeImage) {
        preview = _buildImagePreview(asset);
      } else if (asset.contentType == FilesConstants.mimeTypePdf) {
        return _buildPdfPreviewWithControls();
      } else {
        preview = _buildGenericIcon(asset.contentType);
      }
    } else {
      preview = const Center(
        child: Icon(Icons.folder, size: 80, color: Colors.amber),
      );
    }

    // Proportional height: 200 at width 300, 500 at width 700?
    // Let's use a simpler linear scale or aspect ratio.
    // If width is 300, height is 200. Aspect ratio = 3/2 = 1.5.
    // height = width / 1.5
    final height = (widget.width / 1.5).clamp(200.0, 500.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: height,
        width: double.infinity,
        color: Colors.grey.shade100,
        child: preview,
      ),
    );
  }

  Widget _buildImagePreview(File file) {
    try {
      if (file.thumbnail != null) {
        return Image.memory(base64Decode(file.thumbnail!), fit: BoxFit.contain);
      }
      final ioFile = io.File(file.path);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
    } catch (_) {}
    return _buildGenericIcon(file.contentType);
  }

  Widget _buildPdfPreviewWithControls() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        color: Colors.grey.shade100,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ─── PDF viewer ──────────────────────────────────
            SizedBox(
              height: (widget.width / 1.5).clamp(200.0, 500.0),
              child: _pdfController == null
                  ? const Center(child: CircularProgressIndicator())
                  : PdfView(
                      controller: _pdfController!,
                      scrollDirection: Axis.horizontal,
                      onPageChanged: (page) {
                        if (mounted) setState(() => _pdfCurrentPage = page);
                      },
                    ),
            ),

            // ─── Page navigation bar ─────────────────────────
            if (_pdfTotalPages > 0)
              Container(
                color: Colors.grey.shade200,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _pdfCurrentPage > 1
                          ? () => _pdfController?.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Page $_pdfCurrentPage of $_pdfTotalPages',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      iconSize: 20,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _pdfCurrentPage < _pdfTotalPages
                          ? () => _pdfController?.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeInOut,
                              )
                          : null,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenericIcon(String contentType) {
    IconData icon = Icons.file_present;
    if (contentType == FilesConstants.mimeTypePdf) icon = Icons.picture_as_pdf;
    else if (contentType.startsWith('video/')) icon = Icons.video_file;
    else if (contentType.startsWith('audio/')) icon = Icons.audio_file;
    else if (contentType.startsWith('text/')) icon = Icons.text_snippet;
    return Center(
      child: Icon(icon, size: 80, color: Colors.grey.shade400),
    );
  }

  // ─── File Metadata ────────────────────────────────────────────
  Widget _buildFileMetadataSection(File file) {
    final moment = Moment.fromMillisecondsSinceEpoch(
      file.dateCreated.millisecondsSinceEpoch,
      isUtc: true,
    );
    final modifiedMoment = Moment.fromMillisecondsSinceEpoch(
      file.dateLastModified.millisecondsSinceEpoch,
      isUtc: true,
    );

    return _buildSection(
      title: 'File Info',
      icon: Icons.description_outlined,
      children: [
        _infoRow('Name', file.name),
        _infoRow('Type', file.contentType),
        _infoRow('Size', _formatBytes(file.size)),
        _infoRow('Ext', p.extension(file.name).replaceFirst('.', '').toUpperCase()),
        _infoRow('Created', moment.fromNowPrecise(form: Abbreviation.full, includeWeeks: true)),
        _infoRow('Modified', modifiedMoment.fromNowPrecise(form: Abbreviation.full, includeWeeks: true)),
        _infoRowSelectable('Path', file.path),
      ],
    );
  }

  Widget _buildFolderMetadataSection() {
    return _buildSection(
      title: 'Folder Info',
      icon: Icons.folder_outlined,
      children: [
        _infoRow('Name', widget.asset.name),
        _infoRowSelectable('Path', widget.asset.path),
      ],
    );
  }

  Widget _buildTabbedMetadataSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'GPS'),
            Tab(text: 'EXIF'),
            Tab(text: 'SIMILAR'),
          ],
          labelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          indicatorSize: TabBarIndicatorSize.tab,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 350,
          child: TabBarView(
            children: [
              _buildGpsTab(),
              _buildExifTab(),
              _buildSimilarFilesTab(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGpsTab() {
    if (widget.asset is! File) return const Center(child: Text('Not a file'));
    final file = widget.asset as File;

    final hasDbLocation = file.latitude != null && file.longitude != null;
    final hasExifLocation = _exifData != null &&
        _exifData!.containsKey('GPS GPSLatitude') &&
        _exifData!.containsKey('GPS GPSLongitude');

    if (!hasDbLocation && !hasExifLocation) {
      return const Center(
        child: Text('No GPS data found.', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    double? lat = file.latitude;
    double? lng = file.longitude;

    if (lat == null && hasExifLocation) {
      lat = _parseExifCoordinate(
        _exifData!['GPS GPSLatitude']!,
        _exifData!['GPS GPSLatitudeRef']?.printable ?? 'N',
      );
      lng = _parseExifCoordinate(
        _exifData!['GPS GPSLongitude']!,
        _exifData!['GPS GPSLongitudeRef']?.printable ?? 'E',
      );
    }

    if (lat == null || lng == null) {
      return const Center(
        child: Text('Invalid GPS data.', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('Latitude', lat.toStringAsFixed(6)),
        _infoRow('Longitude', lng.toStringAsFixed(6)),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: LatLng(lat, lng),
                initialZoom: 13,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mydatatools.app',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(lat, lng),
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 40),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildExifTab() {
    if (widget.asset is! File) return const Center(child: Text('Not a file'));
    final file = widget.asset as File;
    if (file.contentType != FilesConstants.mimeTypeImage) {
      return const Center(child: Text('Not an image', style: TextStyle(color: Colors.grey, fontSize: 12)));
    }

    if (_loadingExif) {
      return const Center(child: CircularProgressIndicator());
    }

    final data = _exifData;
    final interestingKeys = [
      'Image Make', 'Image Model', 'EXIF ExposureTime', 'EXIF FNumber',
      'EXIF ISOSpeedRatings', 'EXIF DateTimeOriginal', 'EXIF LensModel',
      'EXIF FocalLength', 'EXIF Flash', 'Image Orientation',
      'EXIF ExifImageWidth', 'EXIF ExifImageLength',
    ];

    final rows = (data == null || data.isEmpty)
        ? <Widget>[]
        : interestingKeys
            .where((k) => data.containsKey(k) && data[k]!.printable.isNotEmpty)
            .map((k) => _infoRow(
                  k.replaceFirst('EXIF ', '').replaceFirst('Image ', ''),
                  data[k]!.printable,
                ))
            .toList();

    if (rows.isEmpty) {
      return const Center(
        child: Text('No EXIF data available.', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }

    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _buildSimilarFilesTab() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome, size: 48, color: Colors.blueAccent),
          SizedBox(height: 12),
          Text('Similar Files', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 4),
          Text('Coming Soon', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  // ─── Shared helpers ───────────────────────────────────────────
  Widget _buildSection({
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: Colors.grey.shade600),
            const SizedBox(width: 4),
            Text(
              title.toUpperCase(),
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.grey.shade600, letterSpacing: 1.1),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w500)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 2),
          ),
        ],
      ),
    );
  }

  Widget _infoRowSelectable(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.w500)),
          const SizedBox(height: 2),
          SelectableText(value, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ),
    );
  }

  double _parseExifCoordinate(IfdTag tag, String ref) {
    try {
      final values = tag.values.toList();
      double d = values[0].numerator / values[0].denominator;
      double m = values[1].numerator / values[1].denominator;
      double s = values[2].numerator / values[2].denominator;
      double result = d + (m / 60) + (s / 3600);
      if (ref == 'S' || ref == 'W') result = -result;
      return result;
    } catch (_) {
      return 0.0;
    }
  }

  String _formatBytes(num bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')} ${suffixes[i]}';
  }
}
