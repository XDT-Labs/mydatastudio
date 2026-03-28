import 'package:flutter/material.dart';

class SectionSubHeaderWidget extends StatelessWidget {
  const SectionSubHeaderWidget({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.2),
      ),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
          fontSize: 9,
        ),
      ),
    );
  }
}
