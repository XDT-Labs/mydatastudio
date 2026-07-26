import 'dart:convert';
import 'dart:io' as io;
import 'package:http/http.dart' as http;
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const _rawExtensions = ['.nef', '.cr2', '.arw', '.dng', '.orf', '.sr2'];

class ThumbnailGenerator {
  /// Generates a JPEG thumbnail for [filePath], writes it into [cache], and
  /// returns the relative cache key to store in `files.thumbnail`
  /// (`<collectionId>/<ab>/<hash>.jpg`). Returns null when no thumbnail could
  /// be produced.
  ///
  /// Non-RAW images are resized locally with the Dart `image` package. RAW
  /// images are sent to the aiserver as **bytes** (base64) — the server decodes
  /// from a buffer and never opens a path (AUDIT H2 is closed by this contract).
  Future<String?> generate(
    String collectionId,
    String fileId,
    String filePath,
    String? contentType,
    ThumbnailCache cache, {
    String? llmServiceUrl,
    String? llmServiceToken,
  }) async {
    final bytes = await _renderJpeg(
      filePath,
      contentType,
      llmServiceUrl: llmServiceUrl,
      llmServiceToken: llmServiceToken,
    );
    if (bytes == null) return null;

    final key = cache.keyFor(collectionId, fileId);
    await cache.writeBytes(key, bytes);
    return key;
  }

  /// Produces resized JPEG bytes for [filePath], or null if it can't be
  /// rendered. RAW files require [llmServiceUrl].
  Future<List<int>?> _renderJpeg(
    String filePath,
    String? contentType, {
    String? llmServiceUrl,
    String? llmServiceToken,
  }) async {
    final ext = p.extension(filePath).toLowerCase();
    final isRaw = _rawExtensions.contains(ext);

    // RAW: send the bytes to the Python service, which decodes them from a
    // buffer (rawpy) and returns a JPEG. The server never opens the path.
    if (isRaw && llmServiceUrl != null) {
      try {
        final rawBytes = await io.File(filePath).readAsBytes();
        final response = await http.post(
          Uri.parse("$llmServiceUrl/util/thumbnail"),
          headers: {
            'Content-Type': 'application/json',
            ...aiServerAuthHeaders(llmServiceToken),
          },
          body: jsonEncode({
            'image_base64': base64Encode(rawBytes),
            'is_raw': true,
            'width': 320,
            'height': 240,
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final b64 = data['thumbnail'] as String?;
          if (b64 != null) return base64Decode(b64);
        }
      } catch (e) {
        print('ThumbnailGenerator: Python service error: $e');
      }
      return null;
    }

    // Non-RAW images: resize locally with the Dart image library.
    if (contentType == FilesConstants.mimeTypeImage && !isRaw) {
      final localFile = io.File(filePath);
      if (localFile.existsSync()) {
        try {
          // Guard against decompression bombs - skip files larger than 50MB
          if (localFile.lengthSync() > 50 * 1024 * 1024) {
            return null;
          }

          img.Image? image = img.decodeImage(localFile.readAsBytesSync());
          if (image != null) {
            img.Image thumb;
            if (image.height >= image.width && image.height > 240) {
              thumb = img.copyResize(image, height: 240);
            } else if (image.width >= image.height && image.width > 320) {
              thumb = img.copyResize(image, width: 320);
            } else {
              thumb = image;
            }
            return img.encodeJpg(thumb);
          }
        } catch (e) {
          print('ThumbnailGenerator: Dart image decode error: $e');
        }
      }
    }

    return null;
  }
}
