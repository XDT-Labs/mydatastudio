import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';

/// Rows for sync folders detected on this Mac, each with an "Add" action.
class FoundFoldersSection extends StatelessWidget {
  const FoundFoldersSection({
    super.key,
    required this.folders,
    required this.onAdd,
  });

  final List<DetectedSyncFolder> folders;
  final void Function(DetectedSyncFolder folder) onAdd;

  static IconData iconFor(SyncProvider provider) => switch (provider) {
    SyncProvider.iCloudDrive => Icons.cloud_outlined,
    SyncProvider.googleDrive => Icons.add_to_drive,
    SyncProvider.dropbox => Icons.cloud_queue,
    SyncProvider.oneDrive => Icons.cloud_circle_outlined,
    SyncProvider.box => Icons.inventory_2_outlined,
    SyncProvider.other => Icons.folder_outlined,
  };

  @override
  Widget build(BuildContext context) {
    if (folders.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No cloud sync folders found on this Mac.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    return Column(
      children: [
        for (final folder in folders)
          ListTile(
            key: ValueKey('found-${folder.path}'),
            leading: Icon(iconFor(folder.provider)),
            title: Text(folder.displayName),
            subtitle: Text(folder.path),
            trailing: FilledButton(
              onPressed: () => onAdd(folder),
              child: const Text('Add'),
            ),
          ),
      ],
    );
  }
}
