import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_source_group.dart';
import 'package:mydatastudio/services/get_collections_service.dart';

/// What the user chose in [showRemovePhotosDialog].
enum RemovePhotosChoice {
  /// Out of the gallery only. The file stays on disk and in its source.
  hide,

  /// Out of the app, and out of the source where the app can reach it —
  /// local originals to the Trash, Drive files to Drive's trash.
  delete,
}

/// Asks what should happen to the selected photos.
///
/// Two actions rather than one because they are genuinely different promises,
/// and a single "Delete" button that only set a flag was the dishonesty this
/// dialog was written to remove. Hiding leaves everything where it is; deleting
/// reaches into the source.
///
/// The copy is built from the actual selection, because what "delete" can do
/// depends on where a photo came from and the user cannot be expected to know
/// that. A local original goes to the Trash and is recoverable. A Drive file
/// goes to Drive's trash. An email attachment cannot be removed from the
/// message at all, so it leaves the app and stays in the mailbox — saying so is
/// the difference between an informed choice and a nasty surprise.
Future<RemovePhotosChoice?> showRemovePhotosDialog(
  BuildContext context,
  List<File> selectedFiles,
) {
  final collections = GetCollectionsService.instance.sink.valueOrNull ?? [];
  final byId = {for (final c in collections) c.id: c};

  final countByGroup = <PhotoSourceGroup, int>{};
  var trashable = 0; // local originals — recoverable from the Trash
  var driveTrashable = 0; // Drive files — recoverable from Drive's trash
  var sourceKeeps = 0; // email attachments — the message keeps its copy

  for (final f in selectedFiles) {
    final collection = byId[f.collectionId];
    final group = photoSourceGroupFor(collection?.scanner);
    countByGroup[group] = (countByGroup[group] ?? 0) + 1;
    switch (group) {
      case PhotoSourceGroup.local:
        trashable++;
      case PhotoSourceGroup.gdrive:
        driveTrashable++;
      case PhotoSourceGroup.gmail:
      case PhotoSourceGroup.yahoo:
      case PhotoSourceGroup.outlook:
      case PhotoSourceGroup.other:
        sourceKeeps++;
    }
  }

  final count = selectedFiles.length;
  final noun = count == 1 ? 'photo' : 'photos';
  final sourceSummary = [
    for (final group in kPhotoSourceGroupOrder)
      if (countByGroup[group] != null)
        '${countByGroup[group]} from ${photoSourceGroupLabel(group)}',
  ].join(', ');

  final deleteLines = <String>[
    if (trashable > 0)
      '$trashable ${trashable == 1 ? 'file' : 'files'} will be moved to the '
          'Trash, where you can still recover ${trashable == 1 ? 'it' : 'them'}.',
    if (driveTrashable > 0)
      '$driveTrashable Google Drive ${driveTrashable == 1 ? 'file' : 'files'} '
          'will be moved to the trash in Google Drive.',
    if (sourceKeeps > 0)
      '$sourceKeeps email ${sourceKeeps == 1 ? 'attachment' : 'attachments'} '
          'will be removed from Photos and Files. The '
          '${sourceKeeps == 1 ? 'email keeps its copy' : 'emails keep their copies'}.',
  ];

  return showDialog<RemovePhotosChoice>(
    context: context,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return AlertDialog(
        backgroundColor: theme.colorScheme.surfaceContainer,
        title: Text('Remove $count $noun?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sourceSummary.isNotEmpty) ...[
              Text(
                'Selected: $sourceSummary.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Text('Hide in gallery', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Removes $noun from the photo gallery only. The files stay on '
              'disk and in their source, and you can un-hide them later.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Text('Delete file', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            for (final line in deleteLines) ...[
              Text('• $line', style: theme.textTheme.bodySmall),
              const SizedBox(height: 2),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(RemovePhotosChoice.hide),
            child: const Text('Hide in gallery'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(RemovePhotosChoice.delete),
            child: const Text('Delete file'),
          ),
        ],
      );
    },
  );
}

/// Exposed for tests: the collection lookup the dialog copy is built from.
Collection? collectionForFile(File file) {
  final collections = GetCollectionsService.instance.sink.valueOrNull ?? [];
  for (final c in collections) {
    if (c.id == file.collectionId) return c;
  }
  return null;
}
