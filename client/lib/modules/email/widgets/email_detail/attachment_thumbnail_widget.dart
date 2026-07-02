import 'dart:io' as io;
import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:open_filex/open_filex.dart';

class AttachmentThumbnailWidget extends StatelessWidget {
  const AttachmentThumbnailWidget({super.key, required this.file});

  final model.File file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isImage = file.contentType.startsWith('image/');

    return GestureDetector(
      onTap: () async {
        if (await io.File(file.path).exists()) {
          await OpenFilex.open(file.path);
        }
      },
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
              color: theme.colorScheme.shadow,
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child:
                  isImage
                      ? Image.file(
                        io.File(file.path),
                        fit: BoxFit.cover,
                        errorBuilder:
                            (context, error, stackTrace) => const Icon(
                              Icons.broken_image,
                              color: Colors.grey,
                            ),
                      )
                      : Center(
                        child: Icon(
                          _iconForType(file.contentType),
                          size: 32,
                          color: Colors.grey.shade400,
                        ),
                      ),
            ),
            Container(
              padding: const EdgeInsets.all(6),
              color: Colors.grey.shade50,
              child: Text(
                file.name,
                style: const TextStyle(
                  fontSize: 10,
                  overflow: TextOverflow.ellipsis,
                ),
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconForType(String? mimeType) {
    if (mimeType == null) return Icons.insert_drive_file;
    if (mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (mimeType.contains('text')) return Icons.description;
    if (mimeType.contains('zip') || mimeType.contains('compressed')) {
      return Icons.folder_zip;
    }
    if (mimeType.contains('video')) return Icons.video_file;
    if (mimeType.contains('audio')) return Icons.audio_file;
    return Icons.insert_drive_file;
  }
}
