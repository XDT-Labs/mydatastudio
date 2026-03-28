import 'dart:convert';

import 'package:flutter/material.dart';

class ThumbnailWidget extends StatelessWidget {
  const ThumbnailWidget({super.key, required this.thumbnail});

  final String thumbnail;

  @override
  Widget build(BuildContext context) {
    if (thumbnail.startsWith('http')) {
      return Image.network(
        thumbnail,
        fit: BoxFit.contain,
        errorBuilder:
            (context, error, stackTrace) => const Center(
              child: Icon(
                Icons.broken_image_outlined,
                size: 40,
                color: Colors.grey,
              ),
            ),
      );
    }
    return Image.memory(base64Decode(thumbnail), fit: BoxFit.contain);
  }
}
