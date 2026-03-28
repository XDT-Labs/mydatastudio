import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/widgets/file_details/info_row.dart';

class GpsMetadataTab extends StatelessWidget {
  const GpsMetadataTab({
    super.key,
    required this.exifData,
    required this.file,
    this.tileProvider,
  });

  final Map<String, IfdTag>? exifData;
  final File file;
  // Injected in tests to avoid HTTP requests; null = normal NetworkTileProvider.
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final hasDbLocation = file.latitude != null && file.longitude != null;
    final hasExifLocation =
        exifData != null &&
        exifData!.containsKey('GPS GPSLatitude') &&
        exifData!.containsKey('GPS GPSLongitude');

    if (!hasDbLocation && !hasExifLocation) {
      return const Center(
        child: Text(
          'No GPS data found.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    double? lat = file.latitude;
    double? lng = file.longitude;

    if (lat == null && hasExifLocation) {
      lat = _parseExifCoordinate(
        exifData!['GPS GPSLatitude']!,
        exifData!['GPS GPSLatitudeRef']?.printable ?? 'N',
      );
      lng = _parseExifCoordinate(
        exifData!['GPS GPSLongitude']!,
        exifData!['GPS GPSLongitudeRef']?.printable ?? 'E',
      );
    }

    if (lat == null || lng == null) {
      return const Center(
        child: Text(
          'Invalid GPS data.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        infoRow('Latitude', lat.toStringAsFixed(6)),
        infoRow('Longitude', lng.toStringAsFixed(6)),
        const SizedBox(height: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: LatLng(lat, lng),
                initialZoom: 13,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mydatatools.app',
                  tileProvider: tileProvider,
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(lat, lng),
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: Colors.red,
                        size: 40,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static double _parseExifCoordinate(IfdTag tag, String ref) {
    try {
      final values = tag.values.toList();
      double d = values[0].numerator / values[0].denominator;
      double m = values[1].numerator / values[1].denominator;
      double s = values[2].numerator / values[2].denominator;
      double result = d + (m / 60) + (s / 3600);
      if (ref == 'S' || ref == 'W') result = -result;
      return result;
    } catch (_) {
      return 0.0;
    }
  }
}
