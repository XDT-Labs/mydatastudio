import 'dart:io' as io;
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mydatastudio/modules/files/services/utilities/decoration_detector.dart';

/// Flat artwork: a handful of colours across the whole canvas, the way a
/// banner or navigation bar is drawn.
img.Image _flatGraphic(int w, int h, {int colors = 12}) {
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final band = ((x + y) ~/ 8) % colors;
      img.drawPixel(image, x, y, img.ColorRgb8(band * 20, 40, 200 - band * 10));
    }
  }
  return image;
}

/// Photographic content: continuous tone plus sensor-style noise, so the
/// palette runs into the thousands the way a real photograph does.
img.Image _photographic(int w, int h) {
  final rng = Random(7);
  final image = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      int jitter(int base) => (base + rng.nextInt(24)).clamp(0, 255);
      img.drawPixel(
        image,
        x,
        y,
        img.ColorRgb8(
          jitter(x * 255 ~/ w),
          jitter(y * 255 ~/ h),
          jitter((x + y) * 255 ~/ (w + h)),
        ),
      );
    }
  }
  return image;
}

void main() {
  final detector = DecorationDetector();

  group('DecorationDetector', () {
    test('a 1x1 spacer is decoration', () {
      expect(detector.isDecoration(img.Image(width: 1, height: 1)), isTrue);
    });

    test('a thin rule is decoration whatever its length', () {
      expect(detector.isDecoration(_flatGraphic(600, 2)), isTrue);
      expect(detector.isDecoration(_flatGraphic(4, 300)), isTrue);
    });

    test('a flat-colour banner is decoration', () {
      // The shape the archive's graphics actually had: 550x314, tens of
      // colours.
      expect(detector.isDecoration(_flatGraphic(550, 314)), isTrue);
    });

    test('a photograph is not decoration', () {
      expect(detector.isDecoration(_photographic(640, 480)), isFalse);
    });

    // The reason aspect ratio is not a signal on its own. A panorama has the
    // same shape as a navigation bar, and hiding someone's panorama is a worse
    // error than leaving a banner in the gallery.
    test('a panorama is not decoration despite banner proportions', () {
      final panorama = _photographic(1600, 400); // 4:1
      expect(panorama.width / panorama.height, greaterThanOrEqualTo(3.0));
      expect(detector.isDecoration(panorama), isFalse);
    });

    test('a wide flat graphic of the same shape still is', () {
      expect(detector.isDecoration(_flatGraphic(1600, 400)), isTrue);
    });

    test('a small photograph just over the size floor is kept', () {
      // 33px clears maxDecorationEdge by one, so only the palette decides.
      expect(detector.isDecoration(_photographic(33, 33)), isFalse);
    });

    group('isDecorationFile', () {
      late io.Directory tempDir;

      setUp(() async {
        tempDir = await io.Directory.systemTemp.createTemp('mds_decor_');
      });
      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      Future<String> write(String name, img.Image image) async {
        final path = '${tempDir.path}/$name';
        await io.File(path).writeAsBytes(img.encodePng(image));
        return path;
      }

      test('classifies from disk', () async {
        expect(
          await detector.isDecorationFile(await write('spacer.png',
              img.Image(width: 1, height: 1))),
          isTrue,
        );
        expect(
          await detector.isDecorationFile(
              await write('photo.png', _photographic(200, 150))),
          isFalse,
        );
      });

      // An unreadable file is not evidence of decoration. Guessing would hide a
      // photograph the user might still want to see — the archive contained a
      // truncated 1997 photo that is recoverable, and hiding it would be wrong.
      test('a missing or undecodable file is not decoration', () async {
        expect(
          await detector.isDecorationFile('${tempDir.path}/nope.png'),
          isFalse,
        );
        final junk = '${tempDir.path}/junk.jpg';
        await io.File(junk).writeAsBytes([0, 5, 22, 7, 0, 2, 0, 0]);
        expect(await detector.isDecorationFile(junk), isFalse);
      });
    });
  });
}
