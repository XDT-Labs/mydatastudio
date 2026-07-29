import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';

/// Resolves a stored `files.thumbnail` value to an [ImageProvider] for the UI.
///
/// The column carries one of three shapes (see [ThumbnailCache]):
///  - `http…`      → remote Google Drive URL   → [NetworkImage]
///  - `<key>.jpg`  → on-disk cache key         → [FileImage] under the cache dir
///  - anything else (long legacy base64)       → [MemoryImage] (transitional)
///
/// Returns null when the value is empty or can't be resolved, so callers can
/// supply their own fallback (an icon, the source file, a placeholder asset).
class ThumbnailResolver {
  static ImageProvider? providerFor(String? thumbnail) {
    if (thumbnail == null || thumbnail.isEmpty) return null;

    if (thumbnail.startsWith('http')) {
      return NetworkImage(thumbnail);
    }

    if (ThumbnailCache.isCacheKey(thumbnail)) {
      final root = MainApp.appDataDirectory.valueOrNull;
      if (root == null) return null;
      return FileImage(ThumbnailCache(root).fileForKey(thumbnail));
    }

    // Legacy inline base64 — kept until the row is regenerated to disk.
    try {
      return MemoryImage(base64Decode(thumbnail));
    } catch (_) {
      return null;
    }
  }
}
