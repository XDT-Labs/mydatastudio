import 'package:flutter/material.dart';

class ComingSoonTabView extends StatelessWidget {
  const ComingSoonTabView({super.key, required this.provider});

  final String provider;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_shared, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '$provider Coming Soon',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: Colors.grey,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            "We're working on integrating this source.",
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
