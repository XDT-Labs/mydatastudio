import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/models/tables/file_chunk.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Handles `{'type': 'embedding', 'table': ..., 'id': ..., ...}` messages sent
/// by the embedding isolates over their control port.
///
/// Three shapes, because three things are being stored. Files carry a single
/// `embedding`; emails carry `embeddings`, one per chunk of the body,
/// replacing whatever the email had before (see
/// [DatabaseRepository.replaceEmailEmbeddings]). Documents carry `chunks` —
/// text and provenance — *and* optionally `embeddings`, because a document
/// chunk is a vector plus the footnote metadata that cites it, and the two
/// have to land together or a search result can match text it cannot show a
/// source for.
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
      case 'file_chunks':
        // `embeddings` may be absent or short: the extractor declines to chunk
        // very large documents (search plan §18a-2), which yields text with no
        // vectors. That document is still worth storing — it stays findable
        // through file_chunks_fts, which is the difference between degrading
        // to keyword search and disappearing.
        final chunks = [
          for (final chunk in message['chunks'] as List)
            FileChunk.fromPortMap(chunk as Map),
        ];
        final vectors = [
          for (final vector in (message['embeddings'] as List?) ?? const [])
            (vector as List).cast<double>(),
        ];
        // One call, one transaction, spanning file_chunks and
        // files_embeddings. It belongs here rather than in the isolate because
        // this runs on the main isolate's connection — the only one that
        // writes — so this is the only place that atomicity is available.
        await repo.replaceFileChunks(id, chunks, embeddings: vectors);
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
