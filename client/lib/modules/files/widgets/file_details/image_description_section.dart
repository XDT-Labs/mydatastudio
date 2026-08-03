import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/section_widget.dart';

/// Shows the AI-generated description for an image (`files.description`),
/// populated in the background by `FileDescriptionIsolate`. Renders nothing
/// while the description hasn't been generated yet, rather than showing an
/// empty section.
class ImageDescriptionSection extends StatelessWidget {
  const ImageDescriptionSection({super.key, required this.description});

  final String? description;

  @override
  Widget build(BuildContext context) {
    final text = description?.trim();
    if (text == null || text.isEmpty) return const SizedBox.shrink();

    return SectionWidget(
      title: 'Description',
      icon: Icons.auto_awesome_outlined,
      children: [Text(text, style: const TextStyle(fontSize: 13))],
    );
  }
}
