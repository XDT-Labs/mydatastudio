import 'package:material_ui/material_ui.dart';

/// Sticky date section header widget used in Photos grid and timeline views.
class DateSectionHeader extends StatelessWidget {
  const DateSectionHeader({
    super.key,
    required this.dateLabel,
    required this.itemCount,
    this.isSelected = false,
    this.onSelectAll,
  });

  final String dateLabel;
  final int itemCount;
  final bool isSelected;
  final ValueChanged<bool>? onSelectAll;

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
        ],
      ),
    );
  }
}
