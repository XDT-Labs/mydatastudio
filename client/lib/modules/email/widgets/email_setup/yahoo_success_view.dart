import 'package:flutter/material.dart';

class YahooSuccessView extends StatelessWidget {
  const YahooSuccessView({super.key, required this.connectedEmail});

  final String? connectedEmail;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Colors.green, size: 64),
        const SizedBox(height: 20),
        const Text(
          'Account Connected!',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        if (connectedEmail != null)
          Text(connectedEmail!, style: const TextStyle(color: Colors.grey)),
      ],
    );
  }
}
