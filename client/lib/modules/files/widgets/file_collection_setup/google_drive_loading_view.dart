import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';

class GoogleDriveLoadingView extends StatelessWidget {
  const GoogleDriveLoadingView({super.key, this.branding});

  /// Defaults to Google Drive.
  final CloudAccountBranding? branding;

  @override
  Widget build(BuildContext context) {
    final b = branding ?? CloudAccountBranding.googleDrive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        b.logo,
        const SizedBox(height: 28),
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(
          'Connecting to ${b.name}…',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        Text(
          'A browser window may open for sign-in.',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
      ],
    );
  }
}
