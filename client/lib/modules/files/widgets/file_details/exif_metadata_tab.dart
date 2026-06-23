import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/info_row.dart';

class ExifMetadataTab extends StatelessWidget {
  const ExifMetadataTab({
    super.key,
    required this.exifData,
    required this.isLoading,
  });

  final Map<String, IfdTag>? exifData;
  final bool isLoading;

  static const _interestingKeys = [
    'Image Make',
    'Image Model',
    'EXIF ExposureTime',
    'EXIF FNumber',
    'EXIF ISOSpeedRatings',
    'EXIF DateTimeOriginal',
    'EXIF LensModel',
    'EXIF FocalLength',
    'EXIF Flash',
    'Image Orientation',
    'EXIF ExifImageWidth',
    'EXIF ExifImageLength',
  ];

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final data = exifData;
    final rows =
        (data == null || data.isEmpty)
            ? <Widget>[]
            : _interestingKeys
                .where(
                  (k) => data.containsKey(k) && data[k]!.printable.isNotEmpty,
                )
                .map(
                  (k) => infoRow(
                    k.replaceFirst('EXIF ', '').replaceFirst('Image ', ''),
                    data[k]!.printable,
                  ),
                )
                .toList();

    if (rows.isEmpty) {
      return const Center(
        child: Text(
          'No EXIF data available.',
          style: TextStyle(color: Colors.grey, fontSize: 12),
        ),
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }
}
