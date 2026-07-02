import 'dart:convert';
import 'dart:io' as io;
import 'package:http/http.dart' as http;
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

class ThumbnailGenerator {
  Future<String?> imageToBase64(File file, {String? llmServiceUrl}) async {
    return pathImageToBase64(
      file.path,
      file.contentType,
      llmServiceUrl: llmServiceUrl,
    );
  }

  Future<String?> pathImageToBase64(
    String filePath,
    String? contentType, {
    String? llmServiceUrl,
  }) async {
    final ext = p.extension(filePath).toLowerCase();
    final isRaw = [
      '.nef',
      '.cr2',
      '.arw',
      '.dng',
      '.orf',
      '.sr2',
    ].contains(ext);

    // If it's a RAW file and we have the Python service, use it!
    if (isRaw && llmServiceUrl != null) {
      try {
        final response = await http.post(
          Uri.parse("$llmServiceUrl/util/thumbnail"),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'file_path': filePath,
            'width': 320,
            'height': 240,
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          return data['thumbnail'];
        }
      } catch (e) {
        print('ThumbnailGenerator: Python service error: $e');
      }
    }

    // Fallback to standard Dart image library for non-RAW images
    if (contentType == FilesConstants.mimeTypeImage && !isRaw) {
      var localFile = io.File(filePath);
      if (localFile.existsSync()) {
        try {
          // Guard against decompression bombs - skip files larger than 50MB
          if (localFile.lengthSync() > 50 * 1024 * 1024) {
            return null;
          }

          img.Image? image = img.decodeImage(localFile.readAsBytesSync());
          if (image != null) {
            img.Image? thumb;
            if (image.height >= image.width && image.height > 240) {
              thumb = img.copyResize(image, height: 240);
            } else if (image.width >= image.height && image.width > 320) {
              thumb = img.copyResize(image, width: 320);
            } else {
              thumb = image;
            }

            final jpg = img.encodeJpg(thumb);
            return base64Encode(jpg);
          }
        } catch (e) {
          print('ThumbnailGenerator: Dart image decode error: $e');
        }
      }
    }

    return null;
  }
}
