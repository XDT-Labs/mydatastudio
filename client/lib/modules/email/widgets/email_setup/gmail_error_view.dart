import 'package:flutter/material.dart';

class GmailErrorView extends StatelessWidget {
  const GmailErrorView({
    super.key,
    required this.errorMessage,
    required this.onRetry,
  });

  final String? errorMessage;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error, color: Colors.red, size: 64),
        const SizedBox(height: 20),
        const Text(
          'Connection Failed',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        const SizedBox(height: 24),
        ElevatedButton(onPressed: onRetry, child: const Text('Try Again')),
      ],
    );
  }
}
