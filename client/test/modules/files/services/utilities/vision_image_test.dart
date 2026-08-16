import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/modules/files/services/utilities/vision_image.dart';

/// A JPEG of the given pixel dimensions, standing in for a camera original.
Uint8List _jpeg(int width, int height, {int? orientation}) {
  final image = img.Image(width: width, height: height);
  // Something non-uniform, so a resize has real content to preserve and the
  // encoder cannot collapse the whole frame to one run.
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 7) % 256, (y * 11) % 256, (x + y) % 256);
    }
  }
  if (orientation != null) {
    image.exif.imageIfd.orientation = orientation;
  }
  return img.encodeJpg(image);
}

int _longestEdge(List<int> bytes) {
  final decoded = img.decodeImage(Uint8List.fromList(bytes))!;
  return decoded.width > decoded.height ? decoded.width : decoded.height;
}

void main() {
  final logger = AppLogger(null);

  test('a camera-sized photo is bounded to the long edge', () async {
    // The whole point. Measured on six real photos: 10.9s per embedding at
    // full size against 3.8s bounded, and a payload 53x smaller. The saving is
    // in base64-ing and decoding a 12MB JPEG, not in the vision tower — the
    // processor caps itself at ~1.3MP regardless.
    final original = _jpeg(4032, 3024);

    final prepared = await VisionImage.prepare(
      original,
      'IMG_1234.jpg',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    expect(prepared, isNotNull);
    expect(_longestEdge(prepared!.bytes), VisionImage.maxEdge);
    expect(
      prepared.bytes.length,
      lessThan(original.length),
      reason: 'the payload crossing to the subprocess should shrink too',
    );
  });

  test('aspect ratio survives, in either orientation', () async {
    final landscape = await VisionImage.prepare(
      _jpeg(4000, 2000),
      'wide.jpg',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );
    final portrait = await VisionImage.prepare(
      _jpeg(2000, 4000),
      'tall.jpg',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    final wide = img.decodeImage(Uint8List.fromList(landscape!.bytes))!;
    final tall = img.decodeImage(Uint8List.fromList(portrait!.bytes))!;
    expect(wide.width, VisionImage.maxEdge);
    expect(wide.height, closeTo(VisionImage.maxEdge / 2, 2));
    expect(tall.height, VisionImage.maxEdge);
    expect(tall.width, closeTo(VisionImage.maxEdge / 2, 2));
  });

  test('an already-small image is passed through untouched', () async {
    // Not merely "not upscaled" — not re-encoded at all. Round-tripping a
    // small image through the JPEG encoder would lose quality for no benefit,
    // and these are the screenshots and web images where fine detail is the
    // only thing the model has to read.
    final original = _jpeg(800, 600);

    final prepared = await VisionImage.prepare(
      original,
      'small.png',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    expect(prepared!.bytes, same(original));
  });

  test('rotation is baked in before the EXIF tag is dropped', () async {
    // Re-encoding discards the orientation tag. A phone stores a portrait
    // photo as a rotated landscape frame plus that tag, so without baking it
    // first the model would be handed a sideways image — and a description of
    // a sideways photo is worse than none.
    final original = _jpeg(4000, 2000, orientation: 6); // rotate 90° CW

    final prepared = await VisionImage.prepare(
      original,
      'rotated.jpg',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    final result = img.decodeImage(Uint8List.fromList(prepared!.bytes))!;
    expect(
      result.height,
      greaterThan(result.width),
      reason: 'orientation 6 makes a 4000x2000 frame display as portrait',
    );
  });

  test(
    'an undecodable non-RAW image is sent as-is rather than dropped',
    () async {
      // The model's decoder is more capable than this one. Skipping the resize
      // costs time; skipping the file costs the user a search result.
      final garbage = Uint8List.fromList(List.filled(64, 0x42));

      final prepared = await VisionImage.prepare(
        garbage,
        'mystery.jpg',
        serviceUrl: 'http://127.0.0.1:1',
        logger: logger,
      );

      expect(prepared!.bytes, same(garbage));
    },
  );

  test('a converted RAW file is renamed to match its new bytes', () async {
    // The regression this exists for. The aiserver picks its decoder from the
    // extension — decode_base64_image routes .nef to rawpy by name alone — so
    // handing it JPEG bytes still called DSC_3753.nef produced "Unsupported
    // file format or not RAW file" and cost that photo its embedding. Every
    // RAW file in the library failed this way.
    final jpegBack = base64Encode(_jpeg(1024, 683));
    final client = MockClient((request) async {
      expect(request.url.path, '/util/thumbnail');
      expect(jsonDecode(request.body)['is_raw'], isTrue);
      return http.Response(jsonEncode({'thumbnail': jpegBack}), 200);
    });

    final prepared = await VisionImage.prepare(
      Uint8List.fromList(List.filled(64, 0x42)),
      'DSC_3753.nef',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
      client: client,
    );

    expect(prepared, isNotNull);
    expect(
      prepared!.fileName,
      'DSC_3753.jpg',
      reason: 'the name must describe the bytes, not the source file',
    );
  });

  test('a locally-resized image is renamed too', () async {
    // Same invariant on the path that never leaves the process. PNG bytes are
    // re-encoded as JPEG, so a .png name would misdescribe them — harmless
    // today because only RAW is routed by extension, but the pairing is what
    // keeps that from mattering.
    final prepared = await VisionImage.prepare(
      _jpeg(3000, 2000),
      'screenshot.png',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    expect(prepared!.fileName, 'screenshot.jpg');
  });

  test('a passed-through image keeps its original name', () async {
    // Untouched bytes must keep their own name — renaming a HEIC that was
    // never converted would point the server at the wrong decoder.
    final prepared = await VisionImage.prepare(
      _jpeg(800, 600),
      'small.png',
      serviceUrl: 'http://127.0.0.1:1',
      logger: logger,
    );

    expect(prepared!.fileName, 'small.png');
  });

  test(
    'a RAW file with no reachable service yields null, not raw bytes',
    () async {
      // RAW cannot be decoded locally and llama.cpp cannot read it either, so
      // passing the original through would hand the model bytes it will fail on.
      // Null means skip, and the caller records a failed attempt.
      final prepared = await VisionImage.prepare(
        Uint8List.fromList(List.filled(64, 0x42)),
        'DSC_2390.nef',
        serviceUrl: 'http://127.0.0.1:1',
        logger: logger,
      );

      expect(prepared, isNull);
    },
  );
}
