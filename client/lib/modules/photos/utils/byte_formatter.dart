import 'dart:math';

/// Utility function to format raw byte counts into human-readable strings (B, KB, MB, GB, etc.)
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  int i = (log(bytes) / log(1024)).floor();
  if (i >= suffixes.length) i = suffixes.length - 1;
  double value = bytes / pow(1024, i);
  String formatted =
      value < 10 && i > 0 ? value.toStringAsFixed(1) : value.toStringAsFixed(0);
  if (formatted.endsWith('.0')) {
    formatted = formatted.substring(0, formatted.length - 2);
  }
  return '$formatted ${suffixes[i]}';
}
