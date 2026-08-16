import 'package:material_ui/material_ui.dart';

/// Sticky date section header widget used in Photos grid and timeline views.
class DateSectionHeader extends StatelessWidget {
  const DateSectionHeader({
    super.key,
    required this.dateLabel,
    required this.itemCount,
    this.isSelected = false,
    this.isCollapsed = false,
    this.onSelectAll,
    this.onToggleCollapsed,
  });

  final String dateLabel;
  final int itemCount;
  final bool isSelected;
  final bool isCollapsed;
  final ValueChanged<bool>? onSelectAll;

  /// Supplied by views that can collapse a section. Null hides the control, so
  /// headers in views without collapse are unchanged.
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      color: colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          if (onSelectAll != null) ...[
            SizedBox(
              height: 24,
              width: 24,
              child: Checkbox(
                value: isSelected,
                onChanged: (val) => onSelectAll?.call(val ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              dateLabel,
              style: textTheme.titleSmall?.copyWith(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (onToggleCollapsed != null)
            IconButton(
              // Same control, same place, same direction as the cluster view's
              // header — the two grouped views are the same grid to the user.
              icon: Icon(isCollapsed ? Icons.chevron_right : Icons.expand_more),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: isCollapsed ? 'Show photos' : 'Hide photos',
              color: colorScheme.onSurfaceVariant,
              onPressed: onToggleCollapsed,
            ),
        ],
      ),
    );
  }
}
