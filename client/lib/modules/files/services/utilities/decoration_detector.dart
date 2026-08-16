import 'dart:io' as io;

import 'package:image/image.dart' as img;
import 'package:mydatastudio/app_logger.dart';

/// Recognises images that decorate an email rather than being photographs:
/// spacer GIFs, bullets, rules, navigation bars, banner graphics.
///
/// These arrive as ordinary attachments, so `is_inline` does not catch them —
/// that flag only covers files the HTML body references with `cid:`. Left alone
/// they sit in the photo gallery forever: a real 1998/1999 archive contributed
/// 186 of them alongside 251 genuine photographs.
///
/// Two signals, both measured against that archive:
///
/// **Size.** Anything 32px or less on either side is a spacer, bullet or rule.
/// No photograph is 20x1.
///
/// **Palette.** Graphics are drawn from flat colour; photographs are not. In the
/// sample the gap was about fiftyfold with nothing in between — every
/// photograph exceeded the 4096-colour sampling cap, while every graphic came
/// in between 12 and 94 distinct colours.
///
/// Aspect ratio is deliberately **not** a signal on its own. It separates
/// banners well (43 of the 186 were 3:1 or wider) but a panorama has the same
/// shape, and mistaking someone's panorama for a navigation bar is a worse
/// error than missing a banner. Wide graphics are caught by their palette
/// instead, which panoramas do not share.
class DecorationDetector {
  DecorationDetector({AppLogger? logger}) : _logger = logger ?? AppLogger(null);

  final AppLogger _logger;

  /// Longest edge, in pixels, at or below which an image is decoration
  /// regardless of anything else.
  static const int maxDecorationEdge = 32;

  /// Distinct colours at or below which an image is treated as drawn rather
  /// than photographed.
  static const int maxFlatPaletteColors = 256;

  /// Cap on colour counting. Photographs blow past this immediately, so there
  /// is no reason to keep counting once it is reached.
  static const int _colorSampleCap = 4096;

  /// Whether [image] is decoration rather than a photograph.
  bool isDecoration(img.Image image) {
    if (image.width <= maxDecorationEdge || image.height <= maxDecorationEdge) {
      return true;
    }
    return _countColors(image) <= maxFlatPaletteColors;
  }

  /// Reads and classifies the image at [path].
  ///
  /// Returns false when the file cannot be read or decoded. An unreadable file
  /// is not evidence of decoration, and guessing would hide a photograph the
  /// user might still want to see and recover.
  Future<bool> isDecorationFile(String path) async {
    try {
      final file = io.File(path);
      if (!file.existsSync()) return false;
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null) return false;
      return isDecoration(decoded);
    } catch (e) {
      _logger.d('DecorationDetector: could not classify $path: $e');
      return false;
    }
  }

  /// Distinct colours, stopping at [_colorSampleCap].
  ///
  /// Large images are sampled on a stride rather than read whole: the question
  /// is whether the palette is flat, and a flat palette is just as obvious from
  /// every fourth pixel as from all of them.
  int _countColors(img.Image image) {
    final stride = image.width * image.height > 250000 ? 4 : 1;
    final seen = <int>{};
    for (var y = 0; y < image.height; y += stride) {
      for (var x = 0; x < image.width; x += stride) {
        final pixel = image.getPixel(x, y);
        // Packed rather than a Pixel object per entry: this runs over every
        // sampled pixel of every imported image.
        seen.add(
          (pixel.r.toInt() << 16) | (pixel.g.toInt() << 8) | pixel.b.toInt(),
        );
        if (seen.length > _colorSampleCap) return seen.length;
      }
    }
    return seen.length;
  }
}
