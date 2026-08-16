import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:path/path.dart' as p;

/// Prepares an image for a model — the embedding encoder or the vision chat
/// model — by decoding it to JPEG and bounding its resolution.
///
/// **The resolution bound is the point, but not for the reason it first
/// appears.** Qwen-VL's own processor already caps input at `max_pixels`
/// (1,310,720 — about 1.3 MP), so a 20 MP photo was never costing the vision
/// tower 20 MP of work; it was being downsampled on arrival. What full-size
/// bytes actually cost is everything *before* that: base64-encoding a 12 MB
/// JPEG, pushing it through a JSON body, and decoding it again.
///
/// Measured on this archive, six real photos: 10.9 s each at full size versus
/// 3.8 s bounded — 2.9x — and the payload fell from 47,964 KB to 912 KB, a 53x
/// reduction in what crosses the HTTP boundary. Across a 2,373-image library
/// that is roughly 7.2 hours against 2.5.
///
/// [maxEdge] sits just under the processor's own ceiling rather than above it,
/// so the bound throws away detail the model would have discarded anyway.
///
/// RAW and HEIC additionally *have* to be converted: llama.cpp's image loader
/// only handles what Pillow's default opener understands and fails outright on
/// them, and the Dart `image` package cannot decode them at all. Those go to
/// the aiserver, which has rawpy and pillow-heif.
class PreparedImage {
  final List<int> bytes;

  /// A name describing [bytes] — **not** always the source file's.
  ///
  /// The aiserver picks its decoder from the extension: `decode_base64_image`
  /// routes `.nef`/`.cr2`/`.dng`/... to rawpy purely by name. So a converted
  /// RAW file still called `DSC_3753.nef` gets JPEG bytes handed to a RAW
  /// decoder, which fails with "Unsupported file format or not RAW file" and
  /// silently costs that photo its embedding. Carrying the name beside the
  /// bytes is what keeps the two from disagreeing.
  final String fileName;

  const PreparedImage(this.bytes, this.fileName);
}

class VisionImage {
  /// Longest edge, in pixels, an image is reduced to.
  ///
  /// Large enough that faces, text on signs and the general composition all
  /// survive — which is what the description model is asked about — and small
  /// enough that the vision tower stays cheap. Aspect ratio is preserved and
  /// images already smaller than this are left alone rather than upscaled.
  static const maxEdge = 1024;

  /// Decompression-bomb guard, matching [ThumbnailGenerator]'s. A modest file
  /// can decode to an arbitrarily large bitmap, and this runs in a background
  /// isolate where an OOM takes the app down with it.
  static const maxDecodeBytes = 50 * 1024 * 1024;

  /// Returns JPEG bytes bounded to [maxEdge], or null when the image cannot be
  /// prepared at all.
  ///
  /// Null means "skip this file", not "use the original": the only way to get
  /// null is a RAW/HEIC conversion failing, and those bytes are unusable by
  /// both models. A *non-RAW* image whose local decode fails falls back to its
  /// original bytes instead — the model can very likely still read a format
  /// the Dart decoder happens not to know, and refusing to embed it would be a
  /// worse outcome than sending it full-size.
  static Future<PreparedImage?> prepare(
    List<int> bytes,
    String fileName, {
    required String serviceUrl,
    String? serviceToken,
    required AppLogger logger,
    int maxEdge = maxEdge,
    http.Client? client,
  }) async {
    final ext = p.extension(fileName).toLowerCase();
    final isRaw = rawImageExtensions.contains(ext);
    final isHeic = heicImageExtensions.contains(ext);

    if (isRaw || isHeic) {
      final converted = await _convertViaService(
        bytes,
        fileName,
        isRaw: isRaw,
        serviceUrl: serviceUrl,
        serviceToken: serviceToken,
        logger: logger,
        maxEdge: maxEdge,
        client: client,
      );
      if (converted == null) return null;
      return PreparedImage(converted, _asJpegName(fileName));
    }

    return _resizeLocally(bytes, fileName, logger: logger, maxEdge: maxEdge);
  }

  /// The same base name with a `.jpg` extension, for bytes that have been
  /// re-encoded. See [PreparedImage.fileName].
  static String _asJpegName(String fileName) =>
      '${p.withoutExtension(fileName)}.jpg';

  /// Decodes and downscales in-process. Cheaper than a round trip, and the
  /// isolate this runs on has nothing else to do while it waits.
  static PreparedImage _resizeLocally(
    List<int> bytes,
    String fileName, {
    required AppLogger logger,
    required int maxEdge,
  }) {
    if (bytes.length > maxDecodeBytes) {
      logger.w(
        'VisionImage: $fileName over ${maxDecodeBytes ~/ (1024 * 1024)}MB, sending as-is',
      );
      return PreparedImage(bytes, fileName);
    }

    try {
      // Avoids copying the buffer when the loader already handed us one —
      // which it does for every local file, and these run to tens of MB.
      final decoded = img.decodeImage(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
      if (decoded == null) return PreparedImage(bytes, fileName);

      final longest =
          decoded.width > decoded.height ? decoded.width : decoded.height;
      if (longest <= maxEdge) return PreparedImage(bytes, fileName);

      // Orientation is baked before the resize, not skipped. Re-encoding drops
      // the EXIF orientation tag, so a portrait photo stored as a rotated
      // landscape frame — which is how most phones write them — would reach
      // the model on its side, and a description of a sideways photo is worse
      // than no description.
      final upright = img.bakeOrientation(decoded);
      final resized =
          upright.width >= upright.height
              ? img.copyResize(upright, width: maxEdge)
              : img.copyResize(upright, height: maxEdge);
      return PreparedImage(
        img.encodeJpg(resized, quality: 90),
        _asJpegName(fileName),
      );
    } catch (e) {
      // See [prepare]: the model's decoder is more capable than this one, so a
      // local failure is a reason to skip the resize, not the file.
      logger.w('VisionImage: could not resize $fileName, sending as-is: $e');
      return PreparedImage(bytes, fileName);
    }
  }

  /// Converts RAW/HEIC through the aiserver, which owns the only decoders for
  /// them. `/util/thumbnail` treats width/height as a bounding box and
  /// preserves aspect ratio, so one square bound gives the same longest-edge
  /// semantics as the local path.
  static Future<List<int>?> _convertViaService(
    List<int> bytes,
    String fileName, {
    required bool isRaw,
    required String serviceUrl,
    String? serviceToken,
    required AppLogger logger,
    required int maxEdge,
    http.Client? client,
  }) async {
    final post = client?.post ?? http.post;
    try {
      final response = await post(
        Uri.parse('$serviceUrl/util/thumbnail'),
        headers: {
          'Content-Type': 'application/json',
          ...aiServerAuthHeaders(serviceToken),
        },
        body: jsonEncode({
          'image_base64': base64Encode(bytes),
          'is_raw': isRaw,
          'width': maxEdge,
          'height': maxEdge,
        }),
      ).timeout(const Duration(seconds: 60));

      if (response.statusCode != 200) {
        logger.e(
          'VisionImage: conversion failed for $fileName: '
          '${response.statusCode} ${response.body}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final b64 = data['thumbnail'] as String?;
      if (b64 == null) {
        logger.w('VisionImage: conversion returned no image for $fileName');
        return null;
      }
      return base64Decode(b64);
    } catch (e) {
      logger.e('VisionImage: error converting $fileName: $e');
      return null;
    }
  }
}
