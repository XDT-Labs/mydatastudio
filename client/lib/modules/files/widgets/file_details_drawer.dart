import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' as io;

import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/models/tables/folder.dart';
import 'package:mydatatools/models/tables/file_asset.dart';
import 'package:mydatatools/modules/files/files_constants.dart';
import 'package:moment_dart/moment_dart.dart';
import 'package:pdfx/pdfx.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:xml/xml.dart';
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:three_js/three_js.dart' as three;
import 'package:three_js_simple_loaders/three_js_simple_loaders.dart';
import 'package:mydatatools/modules/files/widgets/video_file_preview.dart';

class FileDetailsDrawer extends StatefulWidget {
  const FileDetailsDrawer({
    super.key,
    required this.asset,
    required this.width,
    required this.onClose,
    this.onExpand,
  });

  final FileAsset asset;
  final double width;
  final VoidCallback onClose;
  final VoidCallback? onExpand;

  @override
  State<FileDetailsDrawer> createState() => _FileDetailsDrawerState();
}

class _FileDetailsDrawerState extends State<FileDetailsDrawer> {
  Map<String, IfdTag>? _exifData;
  bool _loadingExif = false;

  PdfController? _pdfController;
  int _pdfCurrentPage = 1;
  int _pdfTotalPages = 0;
  bool _loadingPdf = false;
  String? _pdfError;

  String? _textContent;
  bool _loadingText = false;
  bool _isEditing = false;
  final TextEditingController _editController = TextEditingController();
  three.ThreeJS? _threeJs;
  three.OrbitControls? _orbitControls;
  bool _loadingStl = false;
  String? _stlError;

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
      _textContent = null;
      _isEditing = false;
      _editController.clear();
      _orbitControls?.deactivate();
      _orbitControls?.dispose();
      _orbitControls = null;
      _threeJs?.dispose();
      _threeJs = null;
      _loadMetadata();
    }
  }

  @override
  void dispose() {
    _pdfController?.dispose();
    _editController.dispose();
    _orbitControls?.deactivate();
    _orbitControls?.dispose();
    _threeJs?.dispose();
    super.dispose();
  }

  Future<void> _loadMetadata() async {
    if (widget.asset is! File) return;
    final file = widget.asset as File;

    // EXIF for images
    if (_isImage(file)) {
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

    if (mounted) {
      setState(() {
        _pdfController?.dispose();
        _pdfController = null;
        _pdfTotalPages = 0;
        _pdfCurrentPage = 1;
        _loadingPdf = false;
        _pdfError = null;
      });
    }

    // PDF controller
    if (_isPdf(file)) {
      if (mounted) setState(() => _loadingPdf = true);
      try {
        PdfDocument? doc;
        if (file.path.startsWith('gdrive://')) {
          final bytes = await _getGDriveFileBytes(file);
          if (bytes != null) {
            final uint8bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
            doc = await PdfDocument.openData(uint8bytes);
          } else {
            throw 'Failed to download PDF bytes from Google Drive';
          }
        } else {
          final ioFile = io.File(file.path);
          if (await ioFile.exists()) {
            doc = await PdfDocument.openFile(file.path);
          } else {
            throw 'Local PDF file not found: ${file.path}';
          }
        }

        if (doc != null) {
          final pages = doc.pagesCount;
          final controller = PdfController(document: Future.value(doc));
          if (mounted) {
            setState(() {
              _pdfController = controller;
              _pdfTotalPages = pages;
              _pdfCurrentPage = 1;
            });
          }
        }
      } catch (e) {
        debugPrint('Error loading PDF: $e');
        if (mounted) setState(() => _pdfError = e.toString());
      } finally {
        if (mounted) setState(() => _loadingPdf = false);
      }
    }

    // Text content for TXT, HTML, XML, Markdown
    final ext = p.extension(file.name).toLowerCase();
    final textExts = [
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
    if (file.contentType.startsWith('text/') || textExts.contains(ext)) {
      setState(() => _loadingText = true);
      try {
        if (file.path.startsWith('gdrive://')) {
          final bytes = await _getGDriveFileBytes(file);
          if (bytes != null) {
            final content = utf8.decode(bytes);
            if (mounted) setState(() => _textContent = content);
          }
        } else {
          final ioFile = io.File(file.path);
          if (await ioFile.exists()) {
            final content = await ioFile.readAsString();
            if (mounted) setState(() => _textContent = content);
          }
        }
      } catch (e) {
        debugPrint('Error loading text content: $e');
      }
      if (mounted) setState(() => _loadingText = false);
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
      // Prefer direct API media download URL if it's a gdrive:// path
      if (file.path.startsWith('gdrive://')) {
        final fileId = file.path.replaceFirst('gdrive://', '');
        uri = Uri.parse('https://www.googleapis.com/drive/v3/files/$fileId?alt=media');
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
        final bytes = response.bodyBytes;
        debugPrint(
          'Downloaded GDrive file: ${file.name}, length: ${bytes.length}, type: ${bytes.runtimeType}',
        );
        return bytes;
      } else {
        debugPrint(
          'GDrive download failed: ${response.statusCode}, ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Error downloading GDrive file for preview: $e');
    }
    return null;
  }

  Future<void> _saveContent() async {
    if (widget.asset is! File) return;
    final file = widget.asset as File;
    try {
      final ioFile = io.File(file.path);
      await ioFile.writeAsString(_editController.text);
      if (mounted) {
        setState(() {
          _textContent = _editController.text;
          _isEditing = false;
        });
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = widget.asset is File && _isImage(widget.asset as File);
    final tabCount = isImage ? 3 : 1;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(left: BorderSide(color: Colors.grey.shade300, width: 1)),
      ),
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
                      _buildFileMetadataSection(widget.asset as File),
                      const SizedBox(height: 16),
                      _buildTabbedMetadataSection(isImage),
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
  /// Shared preview height: scales with sidebar width, min 200px, max 500px.
  double get _previewHeight => (widget.width / 1.5).clamp(200.0, 500.0);

  /// Wraps any [child] in the standard sized+clipped preview container.
  Widget _previewContainer({required Widget child, Color? background}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: _previewHeight,
        width: double.infinity,
        color: background ?? Colors.grey.shade100,
        child: child,
      ),
    );
  }

  Widget _buildPreviewSection() {
    final asset = widget.asset;

    if (asset is File) {
      final ext = p.extension(asset.name).toLowerCase();
      final textExts = [
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
        return _buildPdfPreviewWithControls();
      } else if (ext == '.stl') {
        return _buildStlPreview(asset);
      } else if (asset.contentType.startsWith('video/') ||
          ['.mp4', '.mov', '.avi', '.mkv', '.m4v', '.webm'].contains(ext)) {
        return _buildVideoPreview(asset);
      } else if (textExts.contains(ext) ||
          asset.contentType.startsWith('text/')) {
        return _buildTextBasedPreview(asset, ext);
      } else if (_isImage(asset) || asset.path.startsWith('gdrive://')) {
        return _previewContainer(child: _buildImagePreview(asset));
      } else {
        return _previewContainer(child: _buildGenericIcon(asset.contentType));
      }
    } else if (asset is Folder) {
      final child = asset.thumbnail != null
          ? _buildThumbnailWidget(asset.thumbnail!)
          : const Center(child: Icon(Icons.folder, size: 80, color: Colors.amber));
      return _previewContainer(child: child);
    }

    return _previewContainer(
      child: const Center(child: Icon(Icons.folder, size: 80, color: Colors.amber)),
    );
  }

  Widget _buildImagePreview(File file) {
    try {
      if (file.thumbnail != null) {
        return _buildThumbnailWidget(file.thumbnail!);
      }
      final ioFile = io.File(file.path);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
    } catch (_) {}
    return _buildGenericIcon(file.contentType);
  }
  
  Widget _buildVideoPreview(File file) {
    return _previewContainer(
      background: Colors.grey.shade900,
      child: VideoFilePreview(
        path: file.path,
        height: _previewHeight,
        isGDrive: file.path.startsWith('gdrive://'),
        onDownloadGDrive: () => _getGDriveFileBytes(file),
      ),
    );
  }

  Widget _buildThumbnailWidget(String thumbnail) {
    if (thumbnail.startsWith('http')) {
      return Image.network(
        thumbnail,
        fit: BoxFit.contain,
        errorBuilder:
            (context, error, stackTrace) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 40,
                color: Colors.grey,
              ),
            ),
      );
    }
    return Image.memory(base64Decode(thumbnail), fit: BoxFit.contain);
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
              height: _previewHeight,
              child: _pdfError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.red, size: 32),
                            const SizedBox(height: 8),
                            Text(
                              'Error loading PDF: $_pdfError',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, color: Colors.red),
                            ),
                          ],
                        ),
                      ),
                    )
                  : (_loadingPdf || _pdfController == null)
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
                      onPressed:
                          _pdfCurrentPage > 1
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
                      onPressed:
                          _pdfCurrentPage < _pdfTotalPages
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
    if (widget.asset is File && _isPdf(widget.asset as File)) {
      icon = Icons.picture_as_pdf;
    } else if (contentType.startsWith('video/')) {
      icon = Icons.video_file;
    } else if (contentType.startsWith('audio/')) {
      icon = Icons.audio_file;
    } else if (contentType.startsWith('text/')) {
      icon = Icons.text_snippet;
    } else if (p.extension(widget.asset.name).toLowerCase() == '.stl') {
      icon = Icons.view_in_ar;
    }
    return Center(child: Icon(icon, size: 80, color: Colors.grey.shade400));
  }

  // ─── STL Preview (3D) ──────────────────────────────────────────
  Widget _buildStlPreview(File file) {
    if (_threeJs == null) {
      _threeJs = three.ThreeJS(
        onSetupComplete: () {
          if (mounted) setState(() {});
        },
        setup: () => _initStlScene(file.path),
      );
    }

    return Container(
      height: _previewHeight,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border.all(color: Colors.blue.withValues(alpha: 0.5)),
      ),
      child: Stack(
        children: [
          // Use a UniqueKey based on the file path to force a fresh widget state whenever the file changes
          KeyedSubtree(key: ValueKey(file.path), child: _threeJs!.build()),
          if (_loadingStl) const Center(child: CircularProgressIndicator()),
          if (_stlError != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text(
                  _stlError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _initStlScene(String filePath) async {
    if (_threeJs == null) return;

    // Camera must be assigned before scene per the three_js pattern
    _threeJs!.camera = three.PerspectiveCamera(
      45,
      _threeJs!.width / _threeJs!.height,
      0.1,
      2000,
    );
    _threeJs!.scene = three.Scene();

    if (mounted) {
      setState(() {
        _loadingStl = true;
        _stlError = null;
      });
    }

    try {
      final scene = _threeJs!.scene;
      final camera = _threeJs!.camera as three.PerspectiveCamera;

      // Dark background
      scene.background = three.Color.fromHex32(0x222222);

      // Ambient light for base illumination
      final ambientLight = three.AmbientLight(0xffffff, 0.8);
      scene.add(ambientLight);

      // Attach a point light to the camera so it always illuminates the model
      // regardless of camera orientation — this is the standard three_js pattern.
      final pointLight = three.PointLight(0xffffff, 1.2);
      camera.add(pointLight);
      scene.add(
        camera,
      ); // camera must be in the scene for its children to render

      // Extra directional light from above for shape definition
      final dirLight = three.DirectionalLight(0xffffff, 0.6);
      dirLight.position.setValues(1, 2, 1);
      scene.add(dirLight);

      final loader = STLLoader();
      three.Mesh? mesh;

      if (filePath.startsWith('gdrive://')) {
        final bytes = await _getGDriveFileBytes(widget.asset as File);
        if (bytes != null) {
          final tempDir = await getTemporaryDirectory();
          final tempFile = io.File(p.join(tempDir.path, 'temp_preview.stl'));
          await tempFile.writeAsBytes(bytes);
          mesh = await loader.fromFile(tempFile);
        }
      } else {
        final file = io.File(filePath);
        if (!await file.exists()) {
          throw 'File does not exist: $filePath';
        }
        mesh = await loader.fromFile(file);
      }

      if (mesh == null) throw 'Could not load STL mesh';
      final geometry = mesh.geometry!;

      final material = three.MeshPhongMaterial({
        three.MaterialProperty.color: three.Color.fromHex32(0x3366ff),
        three.MaterialProperty.specular: three.Color.fromHex32(0x444444),
        three.MaterialProperty.shininess: 80,
      });

      mesh.material = material;
      geometry.computeBoundingBox();
      geometry.center();

      scene.add(mesh);

      // Fit camera to the model's bounding box
      final boundingBox = geometry.boundingBox!;
      final size = three.Vector3();
      boundingBox.getSize(size);
      final maxDim = [size.x, size.y, size.z].reduce((a, b) => a > b ? a : b);

      camera.position.setValues(0, maxDim * 0.5, maxDim * 2.5);
      camera.lookAt(three.Vector3(0, 0, 0));
      camera.updateProjectionMatrix();

      // ── Orbit Controls ─────────────────────────────────────────
      // OrbitControls handles: left-drag → rotate, scroll → zoom,
      // right-drag / shift+drag → pan.
      // We also enable built-in autoRotate so the model spins on load;
      // OrbitControls automatically pauses autoRotate while the user
      // is actively dragging (state != OrbitState.none).
      final controls = three.OrbitControls(camera, _threeJs!.globalKey);
      controls.enableDamping = true; // smooth inertia on release
      controls.dampingFactor = 0.08;
      controls.autoRotate = true;
      controls.autoRotateSpeed = 2.0; // degrees/sec-ish
      controls.enableZoom = true;
      controls.zoomSpeed = 1.2;
      controls.enableRotate = true;
      controls.rotateSpeed = 0.8;
      controls.enablePan = false; // keep it simple for a preview
      controls.minDistance = maxDim * 0.5;
      controls.maxDistance = maxDim * 8.0;
      controls.update();
      _orbitControls = controls;

      // Tell the ThreeJS to call controls.update() every frame so that
      // damping and autoRotate work correctly.
      _threeJs!.addAnimationEvent((_) {
        controls.update();
      });
    } catch (e) {
      debugPrint('Error loading STL: $e');
      if (mounted) setState(() => _stlError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingStl = false);
    }
  }

  // ─── File Metadata ────────────────────────────────────────────
  Widget _buildFileMetadataSection(File file) {
    // Convert to local time for consistent comparison with 'now'
    final createdDateTime = file.dateCreated.toLocal();
    final modifiedDateTime = file.dateLastModified.toLocal();

    final createdMoment = createdDateTime.toMoment();
    final modifiedMoment = modifiedDateTime.toMoment();

    final fullDateFormat = 'MMMM Do, YYYY [at] h:mm:ss A';

    return _buildSection(
      title: 'File Info',
      icon: Icons.description_outlined,
      children: [
        _infoRow('Name', file.name),
        _infoRow('Type', file.contentType),
        _infoRow('Size', _formatBytes(file.size)),
        _infoRow(
          'Ext',
          p.extension(file.name).replaceFirst('.', '').toUpperCase(),
        ),
        _infoRow(
          file.path.startsWith('gdrive://') ? 'Uploaded' : 'Created',
          createdMoment.fromNow(),
          tooltip: createdMoment.format(fullDateFormat),
        ),
        _infoRow(
          'Modified',
          modifiedMoment.fromNow(),
          tooltip: modifiedMoment.format(fullDateFormat),
        ),
        _infoRowSelectable('Path', file.path),
        if (file.downloadUrl != null)
          _infoRowSelectable('Download URL', file.downloadUrl!),
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

  Widget _buildTabbedMetadataSection(bool showExif) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TabBar(
          tabs: [
            if (showExif) const Tab(text: 'GPS'),
            if (showExif) const Tab(text: 'EXIF'),
            const Tab(text: 'SIMILAR'),
          ],
          labelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
          indicatorSize: TabBarIndicatorSize.tab,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 350,
          child: TabBarView(
            children: [
              if (showExif) _buildGpsTab(),
              if (showExif) _buildExifTab(),
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
    final hasExifLocation =
        _exifData != null &&
        _exifData!.containsKey('GPS GPSLatitude') &&
        _exifData!.containsKey('GPS GPSLongitude');

    if (!hasDbLocation && !hasExifLocation) {
      return const Center(
        child: Text(
          'No GPS data found.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
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
        child: Text(
          'Invalid GPS data.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
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
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 40,
                      ),
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
    if (!_isImage(file)) {
      return const Center(
        child: Text(
          'Not an image',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    if (_loadingExif) {
      return const Center(child: CircularProgressIndicator());
    }

    final data = _exifData;
    final interestingKeys = [
      'Image Make',
      'Image Model',
      'EXIF ExposureTime',
      'EXIF FNumber',
      'EXIF ISOSpeedRatings',
      'EXIF DateTimeOriginal',
      'EXIF LensModel',
      'EXIF FocalLength',
      'EXIF Flash',
      'Image Orientation',
      'EXIF ExifImageWidth',
      'EXIF ExifImageLength',
    ];

    final rows =
        (data == null || data.isEmpty)
            ? <Widget>[]
            : interestingKeys
                .where(
                  (k) => data.containsKey(k) && data[k]!.printable.isNotEmpty,
                )
                .map(
                  (k) => _infoRow(
                    k.replaceFirst('EXIF ', '').replaceFirst('Image ', ''),
                    data[k]!.printable,
                  ),
                )
                .toList();

    if (rows.isEmpty) {
      return const Center(
        child: Text(
          'No EXIF data available.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
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
          Text(
            'Coming Soon',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ─── Text/Markdown/Code Previews ────────────────────────────────
  Widget _buildTextBasedPreview(File file, String ext) {
    if (_loadingText) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_textContent == null) {
      return _buildGenericIcon(file.contentType);
    }

    final isMarkdown = ext == '.md' || ext == '.markdown';
    final height = (widget.width / 1.5).clamp(200.0, 500.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: height,
        width: double.infinity,
        color: Colors.white,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Toolbar
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: Colors.grey.shade100,
              child: Row(
                children: [
                  Text(
                    ext.toUpperCase().replaceFirst('.', ''),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                  const Spacer(),
                  if (isMarkdown &&
                      !_isEditing &&
                      !file.path.startsWith('gdrive://'))
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _isEditing = true;
                          _editController.text = _textContent!;
                        });
                      },
                      icon: const Icon(Icons.edit, size: 14),
                      label: const Text('Edit', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(50, 24),
                      ),
                    ),
                  if (_isEditing) ...[
                    TextButton(
                      onPressed: () => setState(() => _isEditing = false),
                      child: const Text(
                        'Cancel',
                        style: TextStyle(fontSize: 11, color: Colors.red),
                      ),
                    ),
                    const SizedBox(width: 4),
                    TextButton(
                      onPressed: _saveContent,
                      child: const Text(
                        'Save',
                        style: TextStyle(fontSize: 11, color: Colors.green),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Content
            Expanded(
              child:
                  _isEditing
                      ? TextField(
                        controller: _editController,
                        maxLines: null,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(12),
                        ),
                        style: const TextStyle(
                          fontFamily: 'Courier',
                          fontSize: 13,
                        ),
                      )
                      : SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: _renderTextContent(ext),
                      ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _renderTextContent(String ext) {
    final content = _textContent!;
    if (ext == '.md' || ext == '.markdown') {
      return MarkdownBody(data: content);
    }
    if (ext == '.xml' || ext == '.xsl' || ext == '.xslt') {
      return Text(
        _tidyXml(content),
        style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
      );
    }
    return Text(
      content,
      style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
    );
  }

  String _tidyXml(String xmlString) {
    try {
      final document = XmlDocument.parse(xmlString);
      return document.toXmlString(pretty: true, indent: '  ');
    } catch (_) {
      return xmlString; // Return as is if it fails to parse
    }
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
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11,
                color: Colors.grey.shade600,
                letterSpacing: 1.1,
              ),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value, {String? tooltip}) {
    Widget valueWidget = Text(
      value,
      style: const TextStyle(fontSize: 12),
      overflow: TextOverflow.ellipsis,
      maxLines: 2,
    );

    if (tooltip != null) {
      valueWidget = Tooltip(message: tooltip, child: valueWidget);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(child: valueWidget),
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
          Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: const TextStyle(fontSize: 11, color: Colors.black54),
          ),
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
    final ext = p.extension(file.name).toLowerCase();
    return ext == '.pdf';
  }
}
