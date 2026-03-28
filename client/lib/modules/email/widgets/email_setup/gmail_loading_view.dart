import 'package:flutter/material.dart';

class GmailLoadingView extends StatelessWidget {
  const GmailLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 20),
        Text(
          'Connecting to Gmail…',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}
