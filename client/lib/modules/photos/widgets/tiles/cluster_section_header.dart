import 'package:flutter/material.dart';

/// Section header for one group in the cluster view.
///
/// Mirrors [DateSectionHeader] so the two grouped views feel like the same
/// grid, with two additions the timeline doesn't need: a placeholder state
/// while the group's label is still being generated, and a "mixed" marker for
/// groups whose members are genuinely heterogeneous.
///
/// The mixed marker matters because a label is a claim about every photo under
/// it. On a loose group — the prototype's worst case mixed living rooms,
/// wedding guests, and kitchens — that claim is wrong for most of them, and
/// saying so is better than quietly presenting a confident but false name.
class ClusterSectionHeader extends StatelessWidget {
  const ClusterSectionHeader({
    super.key,
    required this.label,
    required this.itemCount,
    this.isSelected = false,
    this.isMixed = false,
    this.isLabelPending = false,
    this.isCollapsed = false,
    this.onSelectAll,
    this.onToggleCollapsed,
  });

  final String label;
  final int itemCount;
  final bool isSelected;
  final bool isMixed;
  final bool isLabelPending;
  final bool isCollapsed;
  final ValueChanged<bool>? onSelectAll;
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
          Flexible(
            child: Text(
              label,
              style: textTheme.titleSmall?.copyWith(
                color: isLabelPending
                    ? colorScheme.onSurfaceVariant
                    : colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontStyle: isLabelPending ? FontStyle.italic : FontStyle.normal,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isLabelPending) ...[
            const SizedBox(width: 8),
            SizedBox(
              height: 12,
              width: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (isMixed) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: 'These photos are less alike than the other groups — '
                  'the name may not fit all of them.',
              child: Icon(
                Icons.blur_on,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(width: 8),
          Text(
            '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (onToggleCollapsed != null) ...[
            const SizedBox(width: 4),
            IconButton(
              // Points down when open and right when closed, the direction the
              // content is in — the disclosure convention users already read
              // without thinking about it.
              icon: Icon(
                isCollapsed ? Icons.chevron_right : Icons.expand_more,
              ),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: isCollapsed ? 'Show photos' : 'Hide photos',
              color: colorScheme.onSurfaceVariant,
              onPressed: onToggleCollapsed,
            ),
          ],
        ],
      ),
    );
  }
}
