import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/file_type_icon_widget.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/thumbnail_widget.dart';

class ImagePreviewWidget extends StatelessWidget {
  const ImagePreviewWidget({
    super.key,
    required this.file,
    required this.resolvedPath,
    this.showOriginal = false,
  });

  final File file;
  final String resolvedPath;
  final bool showOriginal;

  @override
  Widget build(BuildContext context) {
    try {
      if (!showOriginal && file.thumbnail != null) {
        return ThumbnailWidget(thumbnail: file.thumbnail!);
      }
      final ioFile = io.File(resolvedPath);
      if (ioFile.existsSync()) {
        return Image.file(ioFile, fit: BoxFit.contain);
      }
      if (file.thumbnail != null) {
        return ThumbnailWidget(thumbnail: file.thumbnail!);
      }
    } catch (_) {}
    return FileTypeIconWidget(
      contentType: file.contentType,
      fileName: file.name,
    );
  }
}
