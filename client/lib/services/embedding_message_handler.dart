import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Handles `{'type': 'embedding', 'table': ..., 'id': ..., 'embedding': ...}`
/// messages sent by the embedding isolates over their control port.
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
  final embedding = (message['embedding'] as List).cast<double>();

  try {
    switch (table) {
      case 'files_embeddings':
        await repo.upsertFileEmbedding(id, embedding);
        break;
      case 'emails_embeddings':
        await repo.upsertEmailEmbedding(id, embedding);
        break;
      default:
        logger.w('handleEmbeddingMessage: unknown table "$table"');
    }
  } catch (e) {
    logger.e('handleEmbeddingMessage: failed to save $table id=$id: $e');
  }
}
