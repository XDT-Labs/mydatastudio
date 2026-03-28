import 'package:flutter/material.dart';
import 'package:mydatatools/modules/files/widgets/file_details/info_row.dart';
import 'package:mydatatools/modules/files/widgets/file_details/section_widget.dart';

class FolderMetadataSection extends StatelessWidget {
  const FolderMetadataSection({
    super.key,
    required this.name,
    required this.path,
  });

  final String name;
  final String path;

  @override
  Widget build(BuildContext context) {
    return SectionWidget(
      title: 'Folder Info',
      icon: Icons.folder_outlined,
      children: [
        infoRow('Name', name),
        infoRowSelectable('Path', path),
      ],
    );
  }
}
