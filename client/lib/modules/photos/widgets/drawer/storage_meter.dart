import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/photos/utils/byte_formatter.dart' as util;

/// A storage usage progress meter widget for the Photos module drawer.
class StorageMeter extends StatelessWidget {
  const StorageMeter({
    super.key,
    required this.usedBytes,
    required this.totalBytes,
  });

  final int usedBytes;
  final int totalBytes;

  static String formatBytes(int bytes) => util.formatBytes(bytes);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final progress =
        totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            backgroundColor: colorScheme.surfaceContainerHighest,
            color: colorScheme.primary,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${formatBytes(usedBytes)} of ${formatBytes(totalBytes)}',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
