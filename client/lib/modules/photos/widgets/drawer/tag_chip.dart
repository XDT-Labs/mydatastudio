import 'package:flutter/material.dart';

/// A compact pill-shaped tag chip widget displaying a tag name and optional count/remove button.
class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.tag,
    required this.onTap,
    this.count,
    this.isActive = false,
    this.onRemove,
  });

  final String tag;
  final int? count;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final formattedTag = tag.startsWith('#') ? tag : '#$tag';
    final labelText = count != null ? '$formattedTag ($count)' : formattedTag;

    final backgroundColor = isActive
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainer;
    final textColor = isActive
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurface;
    final iconColor = isActive
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: 10.0,
            right: onRemove != null ? 4.0 : 10.0,
            top: 4.0,
            bottom: 4.0,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                labelText,
                style: textTheme.labelMedium?.copyWith(
                  color: textColor,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: 2),
                GestureDetector(
                  onTap: onRemove,
                  child: Padding(
                    padding: const EdgeInsets.all(2.0),
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: iconColor,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
