import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/email_folder.dart';

class EmailFolderTileWidget extends StatelessWidget {
  const EmailFolderTileWidget({
    super.key,
    required this.folder,
    required this.label,
    this.icon,
    required this.isSelected,
    required this.onTap,
    this.indent = 48.0,
  });

  final EmailFolder folder;
  final String label;
  final IconData? icon;
  final bool isSelected;
  final VoidCallback onTap;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0, horizontal: 8.0),
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: indent - 8.0),
        leading: icon != null
            ? Icon(
                icon,
                size: 18,
                color: isSelected ? theme.colorScheme.primary : null,
              )
            : null,
        title: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        trailing: (folder.messagesUnread ?? 0) > 0
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  folder.messagesUnread.toString(),
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              )
            : null,
        selected: isSelected,
        selectedTileColor:
            theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        onTap: onTap,
      ),
    );
  }
}
