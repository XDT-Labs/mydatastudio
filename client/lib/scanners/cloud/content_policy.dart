import 'dart:convert';

import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';

enum ContentCategory { images, videos, audio, documents, other }

/// Which cloud files get a local copy, and whether those files are indexed
/// (embedded). Stored as JSON in `collections.content_policy`.
class ContentPolicy {
  final Set<ContentCategory> downloadCategories;

  /// Files larger than this are not downloaded. Null = no cap.
  final int? maxFileBytes;

  /// False excludes the collection's files from embedding.
  final bool index;

  const ContentPolicy({
    required this.downloadCategories,
    this.maxFileBytes,
    this.index = true,
  });

  static final ContentPolicy everything = ContentPolicy(
    downloadCategories: Set.unmodifiable(ContentCategory.values.toSet()),
  );

  static const ContentPolicy nothing = ContentPolicy(downloadCategories: {});

  /// The policy for a collection: the stored JSON, or — for collections that
  /// predate policies — whatever `download_local_copy` implied.
  factory ContentPolicy.resolve({
    required String? json,
    required bool downloadLocalCopy,
  }) {
    if (json != null && json.isNotEmpty) {
      try {
        return ContentPolicy.fromJson(jsonDecode(json) as Map<String, dynamic>);
      } catch (_) {
        // Corrupt value: fall through to the legacy meaning.
      }
    }
    return downloadLocalCopy ? everything : nothing;
  }

  factory ContentPolicy.fromJson(Map<String, dynamic> m) => ContentPolicy(
    downloadCategories: {
      for (final n in (m['categories'] as List? ?? const []))
        for (final c in ContentCategory.values)
          if (c.name == n) c,
    },
    maxFileBytes: m['maxFileBytes'] as int?,
    index: m['index'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'categories': [for (final c in downloadCategories) c.name],
    if (maxFileBytes != null) 'maxFileBytes': maxFileBytes,
    'index': index,
  };

  String encode() => jsonEncode(toJson());

  bool get downloadsAnything => downloadCategories.isNotEmpty;

  bool allowsDownload(ContentCategory category, int? size) =>
      downloadCategories.contains(category) &&
      (maxFileBytes == null || size == null || size <= maxFileBytes!);

  bool shouldDownloadEntry(CloudFileEntry e) =>
      !e.isFolder && allowsDownload(categorize(e.mimeType, e.name), e.size);

  bool shouldDownload(File f) =>
      allowsDownload(categorize(f.contentType, f.name), f.size);

  bool shouldIndex(File f) => index;

  static const _ext = <ContentCategory, Set<String>>{
    ContentCategory.images: {
      'jpg',
      'jpeg',
      'png',
      'gif',
      'heic',
      'heif',
      'tif',
      'tiff',
      'webp',
      'bmp',
      'psd',
      'nef',
      'cr2',
      'arw',
      'dng',
    },
    ContentCategory.videos: {'mp4', 'm4v', 'mov', 'mpeg', 'mpg', 'avi', 'mkv'},
    ContentCategory.audio: {'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg'},
    ContentCategory.documents: {
      'pdf',
      'txt',
      'md',
      'rtf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'odt',
      'ods',
      'csv',
      'pages',
      'numbers',
      'key',
    },
  };

  /// Category from the mime type (provider-style `image/png` or the app's
  /// `application/image`), falling back to the file extension when the mime
  /// type says nothing useful (`application/octet-stream`, unknown, null).
  static ContentCategory categorize(String? mime, String name) {
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/') || m == 'application/image') {
      return ContentCategory.images;
    }
    if (m.startsWith('video/') || m == 'application/video') {
      return ContentCategory.videos;
    }
    if (m.startsWith('audio/') || m == 'application/music') {
      return ContentCategory.audio;
    }
    if (m.startsWith('text/') ||
        m == 'application/pdf' ||
        m == 'application/rtf' ||
        m.startsWith('application/msword') ||
        m.startsWith('application/vnd.ms-') ||
        m.startsWith('application/vnd.openxmlformats-officedocument') ||
        m.startsWith('application/vnd.oasis.opendocument')) {
      return ContentCategory.documents;
    }
    final dot = name.lastIndexOf('.');
    if (dot >= 0) {
      final ext = name.substring(dot + 1).toLowerCase();
      for (final e in _ext.entries) {
        if (e.value.contains(ext)) return e.key;
      }
    }
    return ContentCategory.other;
  }
}
