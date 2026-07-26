import 'package:flutter/material.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_resolver.dart';

class ThumbnailWidget extends StatelessWidget {
  const ThumbnailWidget({super.key, required this.thumbnail});

  final String thumbnail;

  @override
  Widget build(BuildContext context) {
    final provider = ThumbnailResolver.providerFor(thumbnail);
    if (provider == null) return _brokenIcon;

    return Image(
      image: provider,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _brokenIcon,
    );
  }

  static const Widget _brokenIcon = Center(
    child: Icon(Icons.broken_image_outlined, size: 40, color: Colors.grey),
  );
}
