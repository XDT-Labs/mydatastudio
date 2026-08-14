import 'package:material_ui/material_ui.dart';

class ScanningPlaceholderWidget extends StatelessWidget {
  const ScanningPlaceholderWidget({
    super.key,
    this.collectionName,
    this.progress,
    this.message,
    this.detail,
  });

  final String? collectionName;

  /// Fraction complete in 0..1. Null leaves the spinner indeterminate, which is
  /// the right answer for a folder scan of unknown length.
  final double? progress;

  final String? message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(value: progress),
          if (progress != null) ...[
            const SizedBox(height: 12),
            Text(
              '${(progress! * 100).toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            message ?? 'Scanning ${collectionName ?? "emails"}...',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Text(
            detail ?? 'This may take a minute for large folders.',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
