import 'dart:io' as io;
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_generator.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  late ThumbnailGenerator generator;
  late String tempDir;
  late ThumbnailCache cache;

  const collectionId = 'col-1';

  setUp(() async {
    generator = ThumbnailGenerator();
    tempDir = io.Directory.systemTemp.createTempSync('thumb_test').path;
    // Cache root lives under the temp dir; the generator writes files here.
    cache = ThumbnailCache(tempDir);
  });

  tearDown(() {
    io.Directory(tempDir).deleteSync(recursive: true);
  });

  test('writes a cache file and returns its key for a landscape image',
      () async {
    final image = img.Image(width: 800, height: 600);
    img.fill(image, color: img.ColorRgb8(255, 0, 0));
    final path = p.join(tempDir, 'landscape.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    final key = await generator.generate(
      collectionId,
      'file:landscape',
      path,
      FilesConstants.mimeTypeImage,
      cache,
    );

    expect(key, isNotNull);
    // Key encodes the collection and ends in .jpg.
    expect(key, startsWith(collectionId));
    expect(key, endsWith(ThumbnailCache.extension));
    // The bytes were actually written to disk under the cache root.
    expect(cache.existsForKey(key!), isTrue);
    expect(cache.fileForKey(key).lengthSync(), greaterThan(0));
  });

  test('writes a cache file for a portrait image', () async {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(0, 255, 0));
    final path = p.join(tempDir, 'portrait.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    final key = await generator.generate(
      collectionId,
      'file:portrait',
      path,
      FilesConstants.mimeTypeImage,
      cache,
    );

    expect(key, isNotNull);
    expect(cache.existsForKey(key!), isTrue);
  });

  test('returns null (no file written) for non-image files', () async {
    final path = p.join(tempDir, 'test.txt');
    io.File(path).writeAsStringSync('not an image');

    final key = await generator.generate(
      collectionId,
      'file:txt',
      path,
      FilesConstants.mimeTypePdf,
      cache,
    );
    expect(key, isNull);
  });

  test('returns null for missing files', () async {
    final key = await generator.generate(
      collectionId,
      'file:missing',
      p.join(tempDir, 'missing.jpg'),
      FilesConstants.mimeTypeImage,
      cache,
    );
    expect(key, isNull);
  });

  // The generator dispatches on the app's coarse category, not on a real MIME
  // type — a real one falls through and produces nothing at all.
  //
  // This matters because the scanners disagree about what they put on the row.
  // Gmail records the true MIME type (`image/jpeg`); the PST, Yahoo and Outlook
  // scanners record the coarse category. Both therefore have to pass the
  // category *here* regardless of what they store, and handing `part.mimeType`
  // straight through — the obvious-looking simplification — silently stops
  // generating thumbnails for every Gmail attachment. Nothing throws; the
  // column just stays null and the UI falls back to a placeholder forever.
  test('dispatches on the coarse category, not a real MIME type', () async {
    final image = img.Image(width: 400, height: 300);
    img.fill(image, color: img.ColorRgb8(0, 0, 255));
    final path = p.join(tempDir, 'attachment.jpg');
    io.File(path).writeAsBytesSync(img.encodeJpg(image));

    expect(
      await generator.generate(
        collectionId,
        'file:real-mime',
        path,
        'image/jpeg',
        cache,
      ),
      isNull,
      reason: 'a real MIME type is not what the generator matches on',
    );

    final key = await generator.generate(
      collectionId,
      'file:coarse-category',
      path,
      FilesConstants.mimeTypeImage,
      cache,
    );
    expect(key, isNotNull);
    expect(cache.fileForKey(key!).existsSync(), isTrue);
  });

  group('ThumbnailCache', () {
    test('key is stable, sharded, and path-safe for unsafe file ids', () {
      // File ids are `<collectionId>:<relPath>` — full of `:` and `/`.
      const fileId = 'col-1:sub/dir/photo.jpg';
      final key = cache.keyFor(collectionId, fileId);

      expect(cache.keyFor(collectionId, fileId), key, reason: 'stable');
      // <collectionId>/<ab>/<hash>.jpg — three segments, 2-char shard.
      final parts = p.split(key);
      expect(parts.first, collectionId);
      expect(parts[parts.length - 2].length, 2);
      expect(parts.last, endsWith('.jpg'));
      // No raw id characters leaked into the filename.
      expect(key.contains(':'), isFalse);
    });

    test('isCacheKey distinguishes keys from URLs and base64', () {
      expect(ThumbnailCache.isCacheKey('col/ab/hash.jpg'), isTrue);
      expect(ThumbnailCache.isCacheKey('https://drive/thumb'), isFalse);
      expect(ThumbnailCache.isCacheKey('/9j/4AAQSkZJRgABAQ...'), isFalse);
      expect(ThumbnailCache.isCacheKey(null), isFalse);
    });

    test('deleteCollection removes all cached files for the collection',
        () async {
      final key = cache.keyFor(collectionId, 'file:x');
      await cache.writeBytes(key, [1, 2, 3]);
      expect(cache.existsForKey(key), isTrue);

      await cache.deleteCollection(collectionId);
      expect(cache.existsForKey(key), isFalse);
    });
  });
}
