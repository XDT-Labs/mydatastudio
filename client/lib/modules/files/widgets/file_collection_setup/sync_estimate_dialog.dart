import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/photos/utils/byte_formatter.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

/// "~12,340 files, 48 GB; 9.1 GB will be downloaded".
String describeEstimate(CloudSyncEstimate e) {
  final files = e.files.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$files files, ${formatBytes(e.totalBytes)}; '
      '${formatBytes(e.downloadBytes)} will be downloaded';
}

/// Confirm step shown after sign-in and before the collection is created.
/// Pops true to start the sync (estimate finished or skipped), false to cancel.
class SyncEstimateDialog extends StatefulWidget {
  const SyncEstimateDialog({
    super.key,
    required this.api,
    required this.policy,
    this.rootFolderId = 'root',
  });

  final CloudFileApi api;
  final ContentPolicy policy;
  final String rootFolderId;

  @override
  State<SyncEstimateDialog> createState() => _SyncEstimateDialogState();
}

class _SyncEstimateDialogState extends State<SyncEstimateDialog> {
  CloudSyncEstimate? _estimate;
  bool _done = false;
  bool _cancelled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final result = await CloudSyncEstimator.estimate(
        widget.api,
        widget.rootFolderId,
        widget.policy,
        isCancelled: () => _cancelled,
        onProgress: (p) {
          if (mounted) setState(() => _estimate = p);
        },
      );
      if (mounted) {
        setState(() {
          _estimate = result;
          _done = result.complete;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not estimate: $e');
    }
  }

  void _close(bool start) {
    _cancelled = true;
    Navigator.of(context).pop(start);
  }

  @override
  Widget build(BuildContext context) {
    final e = _estimate;
    return AlertDialog(
      title: const Text('Ready to sync'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Text(_error!)
          else if (_done && e != null)
            Text('~${describeEstimate(e)}')
          else ...[
            Text(
              e == null
                  ? 'Estimating…'
                  : 'Counting so far: ${e.files} files, '
                      '${formatBytes(e.totalBytes)}',
            ),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => _close(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => _close(true),
          child: Text(_done ? 'Start sync' : 'Start without estimate'),
        ),
      ],
    );
  }
}
