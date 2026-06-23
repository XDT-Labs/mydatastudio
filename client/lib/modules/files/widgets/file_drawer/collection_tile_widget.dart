import 'package:flutter/material.dart';
import 'package:mydatastudio/models/tables/collection.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 12.0, right: 0.0),
        selected: isSelected,
        selectedTileColor: theme.colorScheme.primaryContainer.withValues(
          alpha: 0.15,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color:
                isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.3)
                    : Colors.transparent,
            width: 1,
          ),
        ),
        title: Text(
          displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color:
                isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
          ),
        ),
        subtitle:
            subtitle != null
                ? Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withOpacity(0.6),
                    fontSize: 11,
                  ),
                )
                : null,
        trailing: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: Icon(
            Icons.more_vert,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
          ),
          onSelected: (value) {
            if (value == 'sync') onSync();
            if (value == 'delete') onDelete();
          },
          itemBuilder:
              (context) => const [
                PopupMenuItem<String>(value: 'sync', child: Text('Sync')),
                PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
              ],
        ),
        onTap: onTap,
      ),
    );
  }
}
