import 'package:flutter/material.dart';
import 'package:moment_dart/moment_dart.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/info_row.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/section_widget.dart';
import 'package:path/path.dart' as p;

class FileMetadataSection extends StatelessWidget {
  const FileMetadataSection({
    super.key,
    required this.file,
    this.resolution,
  });

  final File file;
  final String? resolution;

  @override
  Widget build(BuildContext context) {
    final createdDateTime = file.dateCreated.toLocal();
    final modifiedDateTime = file.dateLastModified.toLocal();
    final createdMoment = createdDateTime.toMoment();
    final modifiedMoment = modifiedDateTime.toMoment();
    const fullDateFormat = 'MMMM Do, YYYY [at] h:mm:ss A';

    return SectionWidget(
      title: 'File Info',
      icon: Icons.description_outlined,
      children: [
        infoRow('Name', file.name),
        infoRow('Type', file.contentType),
        infoRow('Size', _formatBytes(file.size)),
        infoRow(
          'Ext',
          p.extension(file.name).replaceFirst('.', '').toUpperCase(),
        ),
        if (resolution != null)
          infoRow('Resolution', resolution!),
        infoRow(
          file.path.startsWith('gdrive://') ? 'Uploaded' : 'Created',
          createdMoment.fromNow(),
          tooltip: createdMoment.format(fullDateFormat),
        ),
        infoRow(
          'Modified',
          modifiedMoment.fromNow(),
          tooltip: modifiedMoment.format(fullDateFormat),
        ),
        infoRowSelectable('Path', file.path),

        if (file.downloadUrl != null)
          infoRowSelectable('Download URL', file.downloadUrl!),
      ],
    );
  }

  static String _formatBytes(num bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '')} ${suffixes[i]}';
  }
}
