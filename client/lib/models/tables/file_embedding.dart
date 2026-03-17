import 'package:drift/drift.dart';
import 'package:mydatatools/models/tables/converters/float_list_converter.dart';

/// Stores vector embeddings for files, one column per embedding model.
///
/// This design allows adding new embedding models over time by adding new
/// nullable BLOB columns without disturbing existing data. Each column holds
/// a Float32 BLOB of [dimensions * 4] bytes.
///
/// Linked to [Files] via [fileId] (1-to-1).
@TableIndex(name: 'file_embeddings_file_id_idx', columns: {#fileId})
class FilesEmbeddings extends Table {
  /// Primary key — matches the corresponding [Files.id].
  TextColumn get fileId => text()();

  /// 2048-dimensional embedding from Qwen3-Embedding-8B (or Qwen3-VL variant).
  /// Stored as a raw Float32 BLOB via [FloatListConverter].
  BlobColumn get qwen3_8bEmbedding =>
      blob().nullable().map(const FloatListConverter())();

  @override
  Set<Column> get primaryKey => {fileId};
}

