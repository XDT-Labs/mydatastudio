import 'dart:io' as io;
import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/widgets/accessible_tap.dart';
import 'package:open_filex/open_filex.dart';

class AttachmentThumbnailWidget extends StatelessWidget {
  const AttachmentThumbnailWidget({super.key, required this.file});

  final model.File file;

  /// Card width — also the width the image preview is decoded at.
  static const double tileWidth = 120;

  /// True when this attachment should be previewed as a picture.
  ///
  /// Two forms have to be accepted. The PST, Yahoo and Outlook scanners store
  /// the app's own coarse category (`application/image`); only Gmail stores a
  /// real MIME type. Checking for `image/` alone — which is what this did —
  /// meant no PST attachment ever previewed.
  bool get _isImage =>
      file.contentType == FilesConstants.mimeTypeImage ||
      file.contentType.startsWith('image/');

  Future<void> _open(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await io.File(file.path).exists()) {
      messenger.showSnackBar(
        SnackBar(content: Text('${file.name} is no longer on disk')),
      );
      return;
    }
    final result = await OpenFilex.open(file.path);
    if (result.type != ResultType.done) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open ${file.name}: ${result.message}')),
      );
    }
  }

  /// Saves a copy of the attachment wherever the user chooses.
  ///
  /// The extracted file already sits in the app's data directory, so this is a
  /// copy rather than a fetch — but that directory is not somewhere a user
  /// should have to go digging, which is the whole point of the control.
  Future<void> _download(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final source = io.File(file.path);
    if (!await source.exists()) {
      messenger.showSnackBar(
        SnackBar(content: Text('${file.name} is no longer on disk')),
      );
      return;
    }

    try {
      final destination = await FilePicker.platform.saveFile(
        dialogTitle: 'Save attachment',
        fileName: file.name,
      );
      // Null means the user cancelled the dialog — not an error to report.
      if (destination == null) return;

      await source.copy(destination);
      messenger.showSnackBar(SnackBar(content: Text('Saved ${file.name}')));
    } catch (e) {
      AppLogger(null).e("Attachment download failed for ${file.name}: $e");
      messenger.showSnackBar(
        SnackBar(content: Text('Could not save ${file.name}: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Container(
        width: tileWidth,
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
            // Only the preview and name are the "open it" target; the buttons
            // below are separate controls and must not be swallowed by it.
            Expanded(
              child: AccessibleTap(
                label: 'Open attachment ${file.name}',
                tooltip: file.name,
                borderRadius: BorderRadius.circular(4),
                onPressed: () => _open(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _buildPreview(theme)),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      color: theme.colorScheme.surfaceContainer,
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
            ),
            _buildActions(theme, context),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(ThemeData theme) {
    if (!_isImage) {
      return Center(
        child: Icon(
          _iconForType(file.contentType),
          size: 32,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Image.file(
      io.File(file.path),
      fit: BoxFit.cover,
      // Decoded at display size rather than full resolution: a message can
      // carry a dozen camera-sized images, and decoding them whole to fill a
      // 120px card is what makes opening such a message stutter.
      cacheWidth: (tileWidth * 2).round(),
      filterQuality: FilterQuality.medium,
      errorBuilder:
          (context, error, stackTrace) => Center(
            child: Icon(
              Icons.broken_image,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
    );
  }

  Widget _buildActions(ThemeData theme, BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 16),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: 'Open ${file.name}',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _open(context),
          ),
          IconButton(
            icon: const Icon(Icons.download, size: 16),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: 'Save ${file.name}…',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            onPressed: () => _download(context),
          ),
        ],
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
    if (mimeType.contains('audio') || mimeType.contains('music')) {
      return Icons.audio_file;
    }
    return Icons.insert_drive_file;
  }
}
