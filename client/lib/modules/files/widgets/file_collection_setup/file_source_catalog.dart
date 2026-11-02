import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/file_sources/sync_folder/sync_folder_detector.dart';

enum FileSourceGroup {
  thisMac('Folders on this Mac'),
  cloudAccounts('Cloud accounts');

  const FileSourceGroup(this.label);
  final String label;
}

/// Which setup form a source opens.
enum FileSourceForm { folder, googleDrive, none }

/// One tile in the "add a source" catalog. Adding a provider means adding an
/// entry to [FileSource.catalog] and, if it needs one, a new [FileSourceForm].
class FileSource {
  const FileSource({
    required this.id,
    required this.group,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.form,
    this.folderPrompt = 'Select folder to add.',
    this.detected,
    this.alreadyAdded = false,
  });

  /// A sync folder found on this Mac, added as a local folder collection.
  /// One already covered by a collection stays listed but can't be added
  /// again; every other source can be added more than once.
  factory FileSource.detected(
    DetectedSyncFolder folder, {
    bool alreadyAdded = false,
  }) => FileSource(
    id: 'found:${folder.path}',
    group: FileSourceGroup.thisMac,
    title: folder.displayName,
    subtitle: folder.path,
    icon: iconFor(folder.provider),
    form: FileSourceForm.folder,
    folderPrompt: folder.note ?? 'Select folder to add.',
    detected: folder,
    alreadyAdded: alreadyAdded,
  );

  final String id;
  final FileSourceGroup group;
  final String title;
  final String subtitle;
  final IconData icon;
  final FileSourceForm form;

  /// Intro line for [FileSourceForm.folder] sources.
  final String folderPrompt;
  final DetectedSyncFolder? detected;
  final bool alreadyAdded;

  bool get comingSoon => form == FileSourceForm.none;
  bool get available => !comingSoon && !alreadyAdded;

  static IconData iconFor(SyncProvider provider) => switch (provider) {
    SyncProvider.iCloudDrive => Icons.cloud_outlined,
    SyncProvider.googleDrive => Icons.add_to_drive,
    SyncProvider.dropbox => Icons.cloud_queue,
    SyncProvider.oneDrive => Icons.cloud_circle_outlined,
    SyncProvider.box => Icons.inventory_2_outlined,
    SyncProvider.pCloud => Icons.cloud_upload_outlined,
    SyncProvider.proton => Icons.lock_outline,
    SyncProvider.mega => Icons.shield_outlined,
    SyncProvider.syncCom => Icons.sync,
    SyncProvider.other => Icons.folder_outlined,
  };

  static const catalog = <FileSource>[
    FileSource(
      id: 'folder',
      group: FileSourceGroup.thisMac,
      title: 'Any folder',
      subtitle: 'Pick a folder on this Mac',
      icon: Icons.folder_outlined,
      form: FileSourceForm.folder,
    ),
    FileSource(
      id: 'network',
      group: FileSourceGroup.thisMac,
      title: 'Network drive',
      subtitle: 'A mounted NAS or SMB share',
      icon: Icons.lan_outlined,
      form: FileSourceForm.folder,
      folderPrompt:
          'Mount the share in Finder first, then select a folder on it.',
    ),
    FileSource(
      id: 'external',
      group: FileSourceGroup.thisMac,
      title: 'External drive',
      subtitle: 'A USB or Thunderbolt disk',
      icon: Icons.usb_outlined,
      form: FileSourceForm.folder,
      folderPrompt: 'Connect the drive, then select a folder on it.',
    ),
    FileSource(
      id: 'google-drive',
      group: FileSourceGroup.cloudAccounts,
      title: 'Google Drive',
      subtitle: 'Sign in and sync without the Drive app',
      icon: Icons.add_to_drive,
      form: FileSourceForm.googleDrive,
    ),
    FileSource(
      id: 'dropbox',
      group: FileSourceGroup.cloudAccounts,
      title: 'Dropbox',
      subtitle: 'Sign in with Dropbox',
      icon: Icons.cloud_queue,
      form: FileSourceForm.none,
    ),
    FileSource(
      id: 'onedrive',
      group: FileSourceGroup.cloudAccounts,
      title: 'OneDrive',
      subtitle: 'Sign in with Microsoft',
      icon: Icons.cloud_circle_outlined,
      form: FileSourceForm.none,
    ),
    FileSource(
      id: 'box',
      group: FileSourceGroup.cloudAccounts,
      title: 'Box',
      subtitle: 'Sign in with Box',
      icon: Icons.inventory_2_outlined,
      form: FileSourceForm.none,
    ),
  ];
}

/// Searchable, grouped grid of [FileSource] tiles.
class FileSourceCatalog extends StatefulWidget {
  const FileSourceCatalog({
    super.key,
    required this.sources,
    required this.onSelected,
    this.detecting = false,
  });

  final List<FileSource> sources;
  final void Function(FileSource source) onSelected;

  /// True while sync folders are still being looked up.
  final bool detecting;

  @override
  State<FileSourceCatalog> createState() => _FileSourceCatalogState();
}

class _FileSourceCatalogState extends State<FileSourceCatalog> {
  String _query = '';

  bool _matches(FileSource s) {
    final q = _query.trim().toLowerCase();
    return q.isEmpty ||
        s.title.toLowerCase().contains(q) ||
        s.subtitle.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.sources.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: 'Search sources',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 24),
        for (final group in FileSourceGroup.values)
          ..._section(context, group, visible),
        if (visible.isEmpty)
          Text(
            'No sources match "$_query".',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
      ],
    );
  }

  List<Widget> _section(
    BuildContext context,
    FileSourceGroup group,
    List<FileSource> visible,
  ) {
    final items = visible.where((s) => s.group == group).toList();
    if (items.isEmpty) return const [];
    return [
      Text(
        group.label,
        key: ValueKey('group-${group.name}'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 12),
      if (group == FileSourceGroup.thisMac && widget.detecting)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: LinearProgressIndicator(),
        ),
      LayoutBuilder(
        builder: (context, constraints) {
          const gap = 12.0;
          final columns = constraints.maxWidth >= 520 ? 2 : 1;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final s in items)
                SizedBox(
                  width: width,
                  child: FileSourceTile(
                    key: ValueKey('source-${s.id}'),
                    source: s,
                    onTap: s.available ? () => widget.onSelected(s) : null,
                  ),
                ),
            ],
          );
        },
      ),
      const SizedBox(height: 28),
    ];
  }
}

class FileSourceTile extends StatelessWidget {
  const FileSourceTile({super.key, required this.source, this.onTap});

  final FileSource source;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = onTap != null;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  source.icon,
                  size: 22,
                  color: enabled ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            source.title,
                            style: theme.textTheme.titleSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (source.alreadyAdded)
                          _Badge(
                            'Added',
                            scheme.surfaceContainerHighest,
                            scheme.onSurfaceVariant,
                          )
                        else if (source.detected != null)
                          _Badge(
                            'Found',
                            scheme.primaryContainer,
                            scheme.onPrimaryContainer,
                          ),
                        if (source.comingSoon)
                          _Badge(
                            'Soon',
                            scheme.surfaceContainerHighest,
                            scheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.background, this.foreground);
  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(left: 8),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: foreground),
    ),
  );
}
