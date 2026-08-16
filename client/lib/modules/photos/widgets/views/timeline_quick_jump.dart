import 'package:flutter/material.dart';

/// Fixed vertical quick-jump bar widget on the right side of the timeline view.
class TimelineQuickJump extends StatelessWidget {
  const TimelineQuickJump({
    super.key,
    required this.monthLabels,
    required this.onJumpTo,
    this.activeIndex,
    this.photoCounts,
  });

  final List<String> monthLabels;
  final int? activeIndex;
  final ValueChanged<int> onJumpTo;
  final Map<String, int>? photoCounts;

  String _formatShortMonth(String label) {
    if (label.isEmpty) return '';
    final parts = label.trim().split(' ');
    final monthPart = parts.first;
    if (monthPart.length <= 3) {
      return monthPart;
    }
    return monthPart.substring(0, 3);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Container(
      width: 48,
      color: colorScheme.surfaceContainerLow,
      child:
          monthLabels.isEmpty
              ? const SizedBox.shrink()
              : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                itemCount: monthLabels.length,
                itemBuilder: (context, index) {
                  final label = monthLabels[index];
                  final shortMonth = _formatShortMonth(label);
                  final count = photoCounts?[label] ?? photoCounts?[shortMonth];
                  final isActive = activeIndex == index;

                  final String tooltipText =
                      count != null
                          ? '$label ($count ${count == 1 ? 'item' : 'items'})'
                          : label;

                  return Tooltip(
                    message: tooltipText,
                    child: InkWell(
                      onTap: () => onJumpTo(index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(
                          vertical: 6.0,
                          horizontal: 4.0,
                        ),
                        decoration: BoxDecoration(
                          border: Border(
                            left: BorderSide(
                              color:
                                  isActive
                                      ? colorScheme.primary
                                      : Colors.transparent,
                              width: 3.0,
                            ),
                          ),
                          color:
                              isActive
                                  ? colorScheme.primaryContainer.withValues(
                                    alpha: 0.15,
                                  )
                                  : Colors.transparent,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              shortMonth,
                              style: textTheme.labelSmall?.copyWith(
                                color:
                                    isActive
                                        ? colorScheme.primary
                                        : colorScheme.onSurfaceVariant,
                                fontWeight:
                                    isActive
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (count != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                '$count',
                                style: textTheme.labelSmall?.copyWith(
                                  color:
                                      isActive
                                          ? colorScheme.primary.withValues(
                                            alpha: 0.8,
                                          )
                                          : colorScheme.onSurfaceVariant
                                              .withValues(alpha: 0.7),
                                  fontSize: 9,
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
    );
  }
}
