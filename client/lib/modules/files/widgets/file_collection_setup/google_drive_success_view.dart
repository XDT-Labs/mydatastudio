import 'package:flutter/material.dart';

class GoogleDriveSuccessView extends StatelessWidget {
  const GoogleDriveSuccessView({super.key, required this.connectedEmail});

  final String? connectedEmail;

  @override
  Widget build(BuildContext context) {
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
        const Text(
          'Google Drive Connected!',
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
          'Scanning your Drive in the background…',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
        ),
      ],
    );
  }
}
