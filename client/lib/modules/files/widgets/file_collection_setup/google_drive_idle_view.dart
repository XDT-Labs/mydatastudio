import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_sign_in_button.dart';

class GoogleDriveIdleView extends StatelessWidget {
  const GoogleDriveIdleView({
    super.key,
    required this.onConnect,
    required this.saveLocalCopy,
    required this.onSaveLocalCopyChanged,
  });

  final VoidCallback onConnect;
  final bool saveLocalCopy;
  final ValueChanged<bool?> onSaveLocalCopyChanged;

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
        CheckboxListTile(
          value: saveLocalCopy,
          onChanged: onSaveLocalCopyChanged,
          title: const Text(
            'Save a local copy of all cloud files, as a local backup',
            style: TextStyle(fontSize: 13),
          ),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
