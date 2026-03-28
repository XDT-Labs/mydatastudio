import 'package:flutter/material.dart';

class YahooLoadingView extends StatelessWidget {
  const YahooLoadingView({super.key});

  static const Color _yahooPurple = Color(0xFF6001D2);

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(color: _yahooPurple),
        SizedBox(height: 20),
        Text(
          'Verifying connection…',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
