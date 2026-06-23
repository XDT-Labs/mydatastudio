import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late ThumbnailGenerator generator;
  late String tempDir;

  setUp(() async {
    generator = ThumbnailGenerator();
    tempDir = io.Directory.systemTemp.createTempSync('thumb_test').path;
  });

  tearDown(() {
    io.Directory(tempDir).deleteSync(recursive: true);
  });

  test('generates thumbnail for landscape image', () async {
    final image = img.Image(width: 800, height: 600);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    final path = p.join(tempDir, 'landscape.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    final thumbBase64 = await generator.pathImageToBase64(
      path,
      FilesConstants.mimeTypeImage,
    );
    expect(thumbBase64, isNotNull);
    expect(thumbBase64, isNotEmpty);
  });

  test('generates thumbnail for portrait image', () async {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(0, 255, 0));
    final path = p.join(tempDir, 'portrait.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    final thumbBase64 = await generator.pathImageToBase64(
      path,
      FilesConstants.mimeTypeImage,
    );
    expect(thumbBase64, isNotNull);
    expect(thumbBase64, isNotEmpty);
  });

  test('returns null for non-image files', () async {
    final path = p.join(tempDir, 'test.txt');
    io.File(path).writeAsStringSync('not an image');

    final thumbBase64 = await generator.pathImageToBase64(
      path,
      FilesConstants.mimeTypePdf,
    );
    expect(thumbBase64, isNull);
  });

  test('returns null for missing files', () async {
    final thumbBase64 = await generator.pathImageToBase64(
      p.join(tempDir, 'missing.jpg'),
      FilesConstants.mimeTypeImage,
    );
    expect(thumbBase64, isNull);
  });
}
