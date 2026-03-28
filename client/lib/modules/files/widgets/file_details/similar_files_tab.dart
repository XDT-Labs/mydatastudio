import 'package:flutter/material.dart';

class SimilarFilesTab extends StatelessWidget {
  const SimilarFilesTab({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome, size: 48, color: Colors.blueAccent),
          SizedBox(height: 12),
          Text('Similar Files', style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 4),
          Text(
            'Coming Soon',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
