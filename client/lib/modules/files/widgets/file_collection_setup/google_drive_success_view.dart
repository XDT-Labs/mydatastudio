import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';

class GoogleDriveSuccessView extends StatelessWidget {
  const GoogleDriveSuccessView({
    super.key,
    required this.connectedEmail,
    this.branding,
  });

  /// Defaults to Google Drive.
  final CloudAccountBranding? branding;

  final String? connectedEmail;

  @override
  Widget build(BuildContext context) {
    final b = branding ?? CloudAccountBranding.googleDrive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: Color(0xFF0F9D58),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check, color: Colors.white, size: 36),
        ),
        const SizedBox(height: 20),
        Text(
          '${b.name} Connected!',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (connectedEmail != null) ...[
          const SizedBox(height: 6),
          Text(
            connectedEmail!,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          b.scanningNote,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
        ),
      ],
    );
  }
}
