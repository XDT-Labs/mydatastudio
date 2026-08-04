import 'package:flutter/material.dart';

/// A collapsible, filterable group header for the Photos module's Sources
/// list. Tapping the row filters to every collection in the group; tapping
/// the chevron only expands/collapses the nested collection list.
class SourceGroupHeader extends StatelessWidget {
  const SourceGroupHeader({
    super.key,
    required this.label,
    required this.icon,
    required this.isActive,
    required this.isExpanded,
    required this.onTap,
    required this.onToggleExpand,
    this.count,
  });

  final String label;
  final IconData icon;
  final int? count;
  final bool isActive;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final backgroundColor =
        isActive ? colorScheme.primaryContainer : Colors.transparent;
    final textColor =
        isActive ? colorScheme.onPrimaryContainer : colorScheme.onSurface;
    final iconColor = isActive
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        hoverColor: isActive ? null : colorScheme.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: textTheme.bodyMedium?.copyWith(
                    color: textColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8.0,
                    vertical: 2.0,
                  ),
                  decoration: BoxDecoration(
                    color: isActive
                        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                        : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    style: textTheme.labelSmall?.copyWith(
                      color: isActive
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              InkWell(
                onTap: onToggleExpand,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4.0),
                  child: Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: iconColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
