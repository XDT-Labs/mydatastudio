import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_type_icon_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/thumbnail_widget.dart';
import 'package:path/path.dart' as p;

/// Extensions Flutter/Skia can't decode natively (no HEIF codec), so
/// `Image.file` can't render them. The aiserver can, via pillow-heif.
const _serverDecodeExtensions = ['.heic', '.heif'];

class ImagePreviewWidget extends StatefulWidget {
  const ImagePreviewWidget({
    super.key,
    required this.file,
    required this.resolvedPath,
    this.showOriginal = false,
  });

  final File file;
  final String resolvedPath;
  final bool showOriginal;

  @override
  State<ImagePreviewWidget> createState() => _ImagePreviewWidgetState();
}

class _ImagePreviewWidgetState extends State<ImagePreviewWidget> {
  Future<Uint8List?>? _serverPreview;

  bool get _needsServerDecode => _serverDecodeExtensions.contains(
    p.extension(widget.resolvedPath).toLowerCase(),
  );

  @override
  void initState() {
    super.initState();
    _maybeStartServerPreview();
  }

  @override
  void didUpdateWidget(covariant ImagePreviewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolvedPath != widget.resolvedPath ||
        oldWidget.showOriginal != widget.showOriginal) {
      _maybeStartServerPreview();
    }
  }

  void _maybeStartServerPreview() {
    _serverPreview =
        (widget.showOriginal && _needsServerDecode)
            ? _fetchServerPreview()
            : null;
  }

  /// Renders a large (near-original-quality) JPEG via the aiserver for
  /// formats Flutter can't decode on its own. Reuses `/util/thumbnail`
  /// with a generous target size rather than a small thumbnail size.
  Future<Uint8List?> _fetchServerPreview() async {
    final llmServiceUrl = MainApp.llmServiceUrl.valueOrNull;
    if (llmServiceUrl == null) return null;
    try {
      final ioFile = io.File(widget.resolvedPath);
      if (!ioFile.existsSync()) return null;
      if (await ioFile.length() > 100 * 1024 * 1024) return null;

      final bytes = await ioFile.readAsBytes();
      final response = await http
          .post(
            Uri.parse('$llmServiceUrl/util/thumbnail'),
            headers: {
              'Content-Type': 'application/json',
              ...aiServerAuthHeaders(MainApp.llmServiceToken.valueOrNull),
            },
            body: jsonEncode({
              'image_base64': base64Encode(bytes),
              'width': 2400,
              'height': 2400,
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final b64 = data['thumbnail'] as String?;
        if (b64 != null) return base64Decode(b64);
      }
    } catch (_) {}
    return null;
  }

  Widget _fallback() {
    if (widget.file.thumbnail != null) {
      return ThumbnailWidget(thumbnail: widget.file.thumbnail!);
    }
    return FileTypeIconWidget(
      contentType: widget.file.contentType,
      fileName: widget.file.name,
    );
  }

  @override
  Widget build(BuildContext context) {
    try {
      if (!widget.showOriginal && widget.file.thumbnail != null) {
        return ThumbnailWidget(thumbnail: widget.file.thumbnail!);
      }

      if (widget.showOriginal && _needsServerDecode) {
        // SizedBox.expand keeps this widget's footprint constant across the
        // loading -> loaded transition. Without it, the spinner's tiny
        // intrinsic size gets picked up as the InteractiveViewer child's
        // layout size, and swapping in the real Image.memory afterward
        // doesn't grow the surrounding viewer/boundary to match — the photo
        // ends up rendered (and then zoomed) inside that small footprint.
        return SizedBox.expand(
          child: FutureBuilder<Uint8List?>(
            future: _serverPreview,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snapshot.data;
              if (bytes != null) {
                return Image.memory(bytes, fit: BoxFit.contain);
              }
              return _fallback();
            },
          ),
        );
      }

      final ioFile = io.File(widget.resolvedPath);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
      return _fallback();
    } catch (_) {}
    return _fallback();
  }
}
