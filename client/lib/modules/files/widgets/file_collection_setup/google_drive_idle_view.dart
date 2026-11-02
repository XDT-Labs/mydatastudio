import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/content_policy_controls.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

class GoogleDriveIdleView extends StatelessWidget {
  const GoogleDriveIdleView({
    super.key,
    required this.onConnect,
    required this.policy,
    required this.onPolicyChanged,
    this.keepDeletedFiles = false,
    this.onKeepDeletedFilesChanged,
    this.branding,
  });

  /// Defaults to Google Drive.
  final CloudAccountBranding? branding;

  final VoidCallback onConnect;
  final ContentPolicy policy;
  final ValueChanged<ContentPolicy> onPolicyChanged;

  /// Keep files (and their local copies) after they are deleted from Drive.
  final bool keepDeletedFiles;
  final ValueChanged<bool>? onKeepDeletedFilesChanged;

  @override
  Widget build(BuildContext context) {
    final b = branding ?? CloudAccountBranding.googleDrive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        b.logo,
        const SizedBox(height: 24),
        Text(
          'Connect ${b.name}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          b.intro,
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
                  b.accessNote,
                  style: TextStyle(fontSize: 12, color: Colors.blue.shade700),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        b.signInButton(onConnect),
        const SizedBox(height: 12),
        ContentPolicyControls(policy: policy, onChanged: onPolicyChanged),
        SwitchListTile(
          value: keepDeletedFiles,
          onChanged: onKeepDeletedFilesChanged,
          title: Text(b.keepDeletedLabel, style: TextStyle(fontSize: 13)),
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
