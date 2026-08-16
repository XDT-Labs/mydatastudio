import 'package:material_ui/material_ui.dart';

/// A navigation list item widget for the Photos module left drawer.
class DrawerNavItem extends StatelessWidget {
  const DrawerNavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.count,
    this.isActive = false,
    this.onSecondaryAction,
    this.secondaryActionIcon = Icons.delete_outline,
    this.secondaryActionTooltip,
  });

  final String label;
  final IconData icon;
  final int? count;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onSecondaryAction;
  final IconData secondaryActionIcon;
  final String? secondaryActionTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final backgroundColor =
        isActive ? colorScheme.primaryContainer : Colors.transparent;
    final textColor =
        isActive ? colorScheme.onPrimaryContainer : colorScheme.onSurface;
    final iconColor =
        isActive
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
                    color:
                        isActive
                            ? colorScheme.surfaceContainerHighest.withValues(
                              alpha: 0.5,
                            )
                            : colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$count',
                    style: textTheme.labelSmall?.copyWith(
                      color:
                          isActive
                              ? colorScheme.onPrimaryContainer
                              : colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
              if (onSecondaryAction != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: secondaryActionTooltip,
                  icon: Icon(secondaryActionIcon, size: 18, color: iconColor),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  splashRadius: 16,
                  onPressed: onSecondaryAction,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
