import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/content_policy_controls.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_sign_in_button.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

class GoogleDriveIdleView extends StatelessWidget {
  const GoogleDriveIdleView({
    super.key,
    required this.onConnect,
    required this.policy,
    required this.onPolicyChanged,
    this.keepDeletedFiles = false,
    this.onKeepDeletedFilesChanged,
  });

  final VoidCallback onConnect;
  final ContentPolicy policy;
  final ValueChanged<ContentPolicy> onPolicyChanged;

  /// Keep files (and their local copies) after they are deleted from Drive.
  final bool keepDeletedFiles;
  final ValueChanged<bool>? onKeepDeletedFilesChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Image.asset('assets/images/google-drive.png', height: 72),
        const SizedBox(height: 24),
        const Text(
          'Connect Google Drive',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Sign in with your Google account to scan and browse your Drive '
          'files directly from this app.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: Colors.blue.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Requires full Drive access to list, download, and delete files.',
                  style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        GoogleDriveSignInButton(onTap: onConnect),
        const SizedBox(height: 12),
        ContentPolicyControls(policy: policy, onChanged: onPolicyChanged),
        SwitchListTile(
          value: keepDeletedFiles,
          onChanged: onKeepDeletedFilesChanged,
          title: const Text(
            'Keep files deleted from Google Drive',
            style: TextStyle(fontSize: 13),
          ),
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
