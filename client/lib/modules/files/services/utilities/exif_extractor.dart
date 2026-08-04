import 'dart:io' as io;
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:exif/exif.dart';
import 'package:mydatastudio/app_logger.dart';

/// Module logger. AppLogger writes to the session log file as well as the
/// console; a bare print() only reaches the console.
final AppLogger _logger = AppLogger(null);

class ExifExtractor {
  /// Takes an absolute filesystem path rather than a [File] model — scanner
  /// isolates only have the model's DB-relative `path` on hand, and passing
  /// that straight to `io.File` would resolve against the isolate's cwd
  /// instead of the collection root.
  Future<Map<String, dynamic>> extractLatLng(
    String absolutePath,
    String contentType,
  ) async {
    Map<String, dynamic> metadata = {};

    if (contentType == FilesConstants.mimeTypeImage) {
      var localFile = io.File(absolutePath);
      if (localFile.existsSync()) {
        try {
          Map<String, IfdTag> exif = await readExifFromFile(localFile);
          if (exif.containsKey('GPS GPSLatitude') &&
              exif.containsKey('GPS GPSLongitude')) {
            var lat = exifGPSToLatitude(exif);
            var lng = exifGPSToLongitude(exif);
            metadata['latitude'] = lat;
            metadata['longitude'] = lng;
          }
        } catch (e) {
          // Formats the `exif` package doesn't understand (some RAW/HEIC
          // variants) throw instead of returning an empty map — this is a
          // best-effort extraction, not a scan-blocking failure.
          _logger.w('ExifExtractor: failed to read EXIF for $absolutePath: $e');
        }
      }
    }
    _logger.d('ExifExtractor: extracted ${metadata.length} tags');
    return metadata;
  }

  double exifGPSToLatitude(Map<String, IfdTag> tags) {
    final latitudeValue =
        tags['GPS GPSLatitude']!.values
            .toList()
            .map<double>(
              (item) =>
                  (item.numerator.toDouble() / item.denominator.toDouble()),
            )
            .toList();
    final latitudeSignal = tags['GPS GPSLatitudeRef']!.printable;

    double latitude =
        latitudeValue[0] + (latitudeValue[1] / 60) + (latitudeValue[2] / 3600);

    if (latitudeSignal == 'S') latitude = -latitude;

    return latitude;
  }

  double exifGPSToLongitude(Map<String, IfdTag> tags) {
    final longitudeValue =
        tags['GPS GPSLongitude']!.values
            .toList()
            .map<double>(
              (item) =>
                  (item.numerator.toDouble() / item.denominator.toDouble()),
            )
            .toList();
    final longitudeSignal = tags['GPS GPSLongitudeRef']!.printable;

    double longitude =
        longitudeValue[0] +
        (longitudeValue[1] / 60) +
        (longitudeValue[2] / 3600);

    if (longitudeSignal == 'W') longitude = -longitude;

    return longitude;
  }
}
