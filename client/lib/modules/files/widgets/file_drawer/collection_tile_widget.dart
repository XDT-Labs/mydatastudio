import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/collection.dart';

class CollectionTileWidget extends StatelessWidget {
  const CollectionTileWidget({
    super.key,
    required this.collection,
    required this.isSelected,
    required this.displayName,
    this.subtitle,
    required this.onTap,
    required this.onSync,
    required this.onDelete,
  });

  final Collection collection;
  final bool isSelected;
  final String displayName;
  final String? subtitle;
  final VoidCallback onTap;
  final VoidCallback onSync;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 1.0),
      child: ListTile(
        dense: true,
        selected: isSelected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.3,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: Text(
          displayName,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: subtitle != null
            ? Text(
                subtitle!,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.grey,
                  fontSize: 11,
                ),
              )
            : null,
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, size: 18),
          onSelected: (value) {
            if (value == 'sync') onSync();
            if (value == 'delete') onDelete();
          },
          itemBuilder: (context) => const [
            PopupMenuItem<String>(value: 'sync', child: Text('Sync')),
            PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
