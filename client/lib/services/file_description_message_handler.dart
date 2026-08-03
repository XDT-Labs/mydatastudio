import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Handles `{'type': 'fileDescription', 'id':, 'description':, 'tags':,
/// 'landmarks':, 'embedding':}` messages sent by `FileDescriptionIsolate`
/// over its control port.
///
/// Same rationale as `handleEmbeddingMessage`: the isolate only generates
/// the analysis, the main isolate's connection does the actual write.
Future<void> handleFileDescriptionMessage(
  DatabaseRepository repo,
  Map<dynamic, dynamic> message,
  AppLogger logger,
) async {
  final id = message['id'] as String;
  final description = message['description'] as String;
  final tags = (message['tags'] as List).cast<String>();
  final landmarks = (message['landmarks'] as List).cast<String>();
  // Not .cast<double>(): JSON-decoded whole-number components (0, 1, ...)
  // come through as int, and cast's runtime type check throws on those
  // instead of converting them.
  final embedding =
      (message['embedding'] as List).map((e) => (e as num).toDouble()).toList();

  await repo.saveFileDescription(
    id,
    description: description,
    tags: tags,
    landmarks: landmarks,
    embedding: embedding,
  );
}
