import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_source_group.dart';
import 'package:mydatastudio/services/get_collections_service.dart';

/// Confirmation shown before hiding selected photos from the gallery.
///
/// Reused by both the batch-selection toolbar's button and the Delete/Backspace
/// shortcut so the two paths cannot drift apart.
///
/// The copy says "hide", not "delete", because hiding is what actually happens:
/// `is_hidden` is set, and the file stays on disk and in its source. The button
/// this replaced promised to "move selected photos to trash", which was never
/// true of any code path in the app.
///
/// Sources are summarised because hiding a whole cluster group will be a common
/// action, and the user needs to see what is about to disappear before it does.
Future<bool?> showHidePhotosConfirmDialog(
  BuildContext context,
  List<File> selectedFiles,
) {
  final collections = GetCollectionsService.instance.sink.valueOrNull ?? [];
  final scannerByCollectionId = {for (final c in collections) c.id: c.scanner};

  // Grouped the same way the drawer's Sources list groups them — the user has
  // just been picking photos out of those buckets, so the summary has to name
  // the same things.
  final countByGroup = <PhotoSourceGroup, int>{};
  for (final f in selectedFiles) {
    final group = photoSourceGroupFor(scannerByCollectionId[f.collectionId]);
    countByGroup[group] = (countByGroup[group] ?? 0) + 1;
  }
  final sourceSummary = [
    for (final group in kPhotoSourceGroupOrder)
      if (countByGroup[group] != null)
        '${countByGroup[group]} from ${photoSourceGroupLabel(group)}',
  ].join(', ');

  final count = selectedFiles.length;
  final noun = count == 1 ? 'photo' : 'photos';

  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Theme.of(ctx).colorScheme.surfaceContainer,
      title: Text('Hide $count $noun?'),
      content: Text(
        'This hides $count $noun'
        '${sourceSummary.isNotEmpty ? ' ($sourceSummary)' : ''} from the '
        'gallery. The original files are not deleted from disk or from '
        'their source — you can still find them in the Files or Email '
        'module.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Hide'),
        ),
      ],
    ),
  );
}
