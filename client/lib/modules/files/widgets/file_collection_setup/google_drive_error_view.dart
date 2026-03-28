import 'package:flutter/material.dart';

class GoogleDriveErrorView extends StatelessWidget {
  const GoogleDriveErrorView({
    super.key,
    required this.errorMessage,
    required this.onRetry,
    required this.onCancel,
  });

  final String? errorMessage;
  final VoidCallback onRetry;
  final VoidCallback onCancel;

  static const Color _googleBlue = Color(0xFF4285F4);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: Color(0xFFDB4437),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.error_outline, color: Colors.white, size: 36),
        ),
        const SizedBox(height: 20),
        const Text(
          'Connection Failed',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (errorMessage != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Text(
              errorMessage!,
              style: TextStyle(
                fontSize: 13,
                color: Colors.red.shade700,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onCancel,
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _googleBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
