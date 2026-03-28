import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

class FileTypeIconWidget extends StatelessWidget {
  const FileTypeIconWidget({
    super.key,
    required this.contentType,
    this.fileName = '',
    this.isPdf = false,
  });

  final String contentType;
  final String fileName;
  final bool isPdf;

  @override
  Widget build(BuildContext context) {
    IconData icon = Icons.file_present;
    if (isPdf) {
      icon = Icons.picture_as_pdf;
    } else if (contentType.startsWith('video/')) {
      icon = Icons.video_file;
    } else if (contentType.startsWith('audio/')) {
      icon = Icons.audio_file;
    } else if (contentType.startsWith('text/')) {
      icon = Icons.text_snippet;
    } else if (p.extension(fileName).toLowerCase() == '.stl') {
      icon = Icons.view_in_ar;
    }
    return Center(child: Icon(icon, size: 80, color: Colors.grey.shade400));
  }
}
