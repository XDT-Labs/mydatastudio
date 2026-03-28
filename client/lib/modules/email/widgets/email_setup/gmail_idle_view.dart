import 'package:flutter/material.dart';

class GmailIdleView extends StatelessWidget {
  const GmailIdleView({super.key, required this.onConnect});

  final VoidCallback onConnect;

  static const Color _googleBlue = Color(0xFF4285F4);

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.email, size: 72, color: _googleBlue),
        const SizedBox(height: 24),
        const Text(
          'Connect Gmail',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Sign in with your Google account to scan and backup your emails '
          'directly to this app.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Colors.grey.shade600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 28),
        GmailSignInButton(onTap: onConnect),
      ],
    );
  }
}

class GmailSignInButton extends StatelessWidget {
  const GmailSignInButton({super.key, required this.onTap});

  final VoidCallback onTap;

  static const Color _googleBlue = Color(0xFF4285F4);

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.g_mobiledata, size: 24, color: _googleBlue),
      label: const Text('Sign in with Google'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: Colors.grey.shade300),
        ),
      ),
    );
  }
}
