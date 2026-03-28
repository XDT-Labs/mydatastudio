import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/widgets/file_details/file_type_icon_widget.dart';
import 'package:mydatatools/modules/files/widgets/file_details/thumbnail_widget.dart';

class ImagePreviewWidget extends StatelessWidget {
  const ImagePreviewWidget({
    super.key,
    required this.file,
    required this.resolvedPath,
  });

  final File file;
  final String resolvedPath;

  @override
  Widget build(BuildContext context) {
    try {
      if (file.thumbnail != null) {
        return ThumbnailWidget(thumbnail: file.thumbnail!);
      }
      final ioFile = io.File(resolvedPath);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
    } catch (_) {}
    return FileTypeIconWidget(
      contentType: file.contentType,
      fileName: file.name,
    );
  }
}
