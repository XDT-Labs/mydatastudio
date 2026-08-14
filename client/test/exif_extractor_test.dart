import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/utilities/exif_extractor.dart';

/// Regression coverage for the Photos map view bug where GPS coordinates
/// were never written to the DB: `local_file_isolate.dart` used to build
/// each scanned [File] without ever calling [ExifExtractor], so
/// `latitude`/`longitude` stayed NULL for every photo even when the file's
/// own EXIF data had GPS tags — see photos_repository.dart's
/// `photosWithLocation`, which filters on those columns.
void main() {
  final extractor = ExifExtractor();

  test('reads GPS lat/lng from a JPEG with GPS EXIF tags', () async {
    final metadata = await extractor.extractLatLng(
      'test/resources/gps-536x354.jpg',
      FilesConstants.mimeTypeImage,
    );

    expect(metadata['latitude'], closeTo(37.7749, 0.0001));
    expect(metadata['longitude'], closeTo(-122.4194, 0.0001));
  });

  test('returns an empty map for a JPEG with no GPS EXIF tags', () async {
    final metadata = await extractor.extractLatLng(
      'test/resources/128-536x354-32kb.jpg',
      FilesConstants.mimeTypeImage,
    );

    expect(metadata['latitude'], isNull);
    expect(metadata['longitude'], isNull);
  });

  test('skips extraction entirely for non-image content types', () async {
    final metadata = await extractor.extractLatLng(
      'test/resources/gps-536x354.jpg',
      FilesConstants.mimeTypePdf,
    );

    expect(metadata, isEmpty);
  });

  test('returns an empty map for a path that does not exist', () async {
    final metadata = await extractor.extractLatLng(
      'test/resources/does-not-exist.jpg',
      FilesConstants.mimeTypeImage,
    );

    expect(metadata, isEmpty);
  });
}
