import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Handles `{'type': 'embedding', 'table': ..., 'id': ..., ...}` messages sent
/// by the embedding isolates over their control port.
///
/// Files carry a single `embedding`; emails carry `embeddings`, one per chunk
/// of the body, replacing whatever the email had before (see
/// [DatabaseRepository.replaceEmailEmbeddings]).
///
/// The embedding isolates open their own read-only-in-practice `AppDatabase`
/// connection to poll for pending work, but no longer write results directly.
/// Instead they hand the vector back to the main isolate, which writes it
/// through `DatabaseManager.instance.repository` — the single connection
/// resqlite serializes writes through internally — avoiding the SQLITE_BUSY
/// contention that came from multiple isolates opening independent
/// connections and writing to the same file concurrently.
Future<void> handleEmbeddingMessage(
  DatabaseRepository repo,
  Map<dynamic, dynamic> message,
  AppLogger logger,
) async {
  final table = message['table'] as String;
  final id = message['id'] as String;
  // Which kind of vector this is — the image itself ('file', the default) or
  // its description's text. Both live in files_embeddings keyed by
  // (file_id, type), so losing this would have one overwrite the other.
  final embeddingType = message['embeddingType'] as String? ?? 'file';

  try {
    switch (table) {
      case 'files_embeddings':
        final embedding = (message['embedding'] as List).cast<double>();
        await repo.upsertFileEmbedding(id, embedding, type: embeddingType);
        break;
      case 'emails_embeddings':
        final embeddings = [
          for (final chunk in message['embeddings'] as List)
            (chunk as List).cast<double>(),
        ];
        await repo.replaceEmailEmbeddings(id, embeddings);
        break;
      default:
        logger.w('handleEmbeddingMessage: unknown table "$table"');
    }
  } catch (e, stackTrace) {
    logger.e(
      'handleEmbeddingMessage: failed to save $table id=$id: $e',
      error: e,
      stackTrace: stackTrace,
    );
  }
}
