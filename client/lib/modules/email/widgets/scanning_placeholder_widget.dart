import 'package:flutter/material.dart';

class ScanningPlaceholderWidget extends StatelessWidget {
  const ScanningPlaceholderWidget({super.key, this.collectionName});

  final String? collectionName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Scanning ${collectionName ?? "emails"}...',
            style: const TextStyle(fontSize: 16, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          const Text(
            'This may take a minute for large folders.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
