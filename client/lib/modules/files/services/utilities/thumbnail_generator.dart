import 'dart:convert';
import 'dart:io' as io;
import 'package:http/http.dart' as http;
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

/// RAW extensions the aiserver decodes via rawpy (`is_raw: true`). Also used
/// by FileDescriptionIsolate to know when a vision-model image needs
/// converting to JPEG first, since llama.cpp's image loader can't read RAW.
const rawImageExtensions = ['.nef', '.cr2', '.arw', '.dng', '.orf', '.sr2'];

/// Formats the Dart `image` package can't decode locally but the aiserver
/// can (via pillow-heif registered with PIL). Unlike RAW these decode with
/// plain PIL.Image.open once the HEIF opener is registered, so `is_raw`
/// stays false for these. Also used by FileDescriptionIsolate — see above.
const heicImageExtensions = ['.heic', '.heif'];

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
    final isRaw = rawImageExtensions.contains(ext);
    final isHeic = heicImageExtensions.contains(ext);

    // RAW/HEIC: send the bytes to the Python service, which decodes them
    // from a buffer (rawpy for RAW, PIL+pillow-heif for HEIC) and returns a
    // JPEG. The server never opens the path.
    if ((isRaw || isHeic) && llmServiceUrl != null) {
      try {
        // RAW files run 30-100MB+; the non-RAW branch below caps decode input
        // at 50MB, and base64-ing an uncapped file into a JSON body is worse.
        final rawLength = await io.File(filePath).length();
        if (rawLength > 100 * 1024 * 1024) {
          _logger.w('ThumbnailGenerator: file over 100MB, skipping: $filePath');
          return null;
        }
        final rawBytes = await io.File(filePath).readAsBytes();
        final response = await http
            .post(
              Uri.parse("$llmServiceUrl/util/thumbnail"),
              headers: {
                'Content-Type': 'application/json',
                ...aiServerAuthHeaders(llmServiceToken),
              },
              body: jsonEncode({
                'image_base64': base64Encode(rawBytes),
                'is_raw': isRaw,
                'width': 320,
                'height': 240,
              }),
            )
            // Without this an unresponsive aiserver hangs the generator forever.
            .timeout(const Duration(seconds: 60));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final b64 = data['thumbnail'] as String?;
          if (b64 != null) return base64Decode(b64);
        }
      } catch (e) {
        _logger.w('ThumbnailGenerator: Python service error: $e');
      }
      return null;
    }

    // Non-RAW, non-HEIC images: resize locally with the Dart image library.
    if (contentType == FilesConstants.mimeTypeImage && !isRaw && !isHeic) {
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
          _logger.w('ThumbnailGenerator: Dart image decode error: $e');
        }
      }
    }

    return null;
  }
}
