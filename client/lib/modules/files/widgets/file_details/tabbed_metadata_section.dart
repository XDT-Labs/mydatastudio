import 'package:exif/exif.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/exif_metadata_tab.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/gps_metadata_tab.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/similar_files_tab.dart';

class TabbedMetadataSection extends StatelessWidget {
  const TabbedMetadataSection({
    super.key,
    required this.file,
    required this.exifData,
    required this.isLoadingExif,
    required this.showExif,
    this.tileProvider,
  });

  final File file;
  final Map<String, IfdTag>? exifData;
  final bool isLoadingExif;
  final bool showExif;
  // Passed through to GpsMetadataTab for test injection.
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TabBar(
          tabs: [
            if (showExif) const Tab(text: 'GPS'),
            if (showExif) const Tab(text: 'EXIF'),
            const Tab(text: 'SIMILAR'),
          ],
          labelStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
          indicatorSize: TabBarIndicatorSize.tab,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 350,
          child: TabBarView(
            children: [
              if (showExif)
                GpsMetadataTab(
                  exifData: exifData,
                  file: file,
                  tileProvider: tileProvider,
                ),
              if (showExif)
                ExifMetadataTab(exifData: exifData, isLoading: isLoadingExif),
              const SimilarFilesTab(),
            ],
          ),
        ),
      ],
    );
  }
}
