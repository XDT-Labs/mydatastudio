import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/services/update_checker.dart';
import 'package:url_launcher/url_launcher.dart';

/// Tells the user a newer release exists and sends them to the GitHub release
/// page to download the DMG. Deliberately not modal-blocking work: the app is
/// fully usable on the old version, so "Later" is a first-class answer.
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  ReleaseUpdate update,
) async {
  final logger = AppLogger(null);

  await showDialog<void>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text('MyData Studio ${update.version} is available'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Download the new version, then drag it to your Applications '
                'folder to replace this one. Your data and settings stay '
                'where they are.',
              ),
              if (update.notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text(
                  "What's new",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: SingleChildScrollView(
                    child: MarkdownBody(data: update.notes),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              UpdateChecker.skipVersion(update.version);
              Navigator.of(context).pop();
            },
            child: const Text('Skip This Version'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Download'),
            onPressed: () async {
              final uri = Uri.parse(update.pageUrl);
              // Closes first: launching the browser pulls focus away, and a
              // dialog left behind the browser window reads as a hang.
              Navigator.of(context).pop();
              if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
                logger.e('[update] Could not open $uri');
              }
            },
          ),
        ],
      );
    },
  );
}
