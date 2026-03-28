import 'package:flutter/material.dart';

class StepIndicatorWidget extends StatelessWidget {
  const StepIndicatorWidget({
    super.key,
    required this.number,
    required this.text,
    this.color = const Color(0xFF6001D2),
  });

  final int number;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$number. ',
            style: TextStyle(fontWeight: FontWeight.bold, color: color),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade800),
            ),
          ),
        ],
      ),
    );
  }
}
