import 'package:flutter/material.dart';

class GoogleDriveLoadingView extends StatelessWidget {
  const GoogleDriveLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/images/google-drive.png', height: 72),
        const SizedBox(height: 28),
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        const Text(
          'Connecting to Google Drive…',
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
