import 'dart:typed_data';

class FileEmbedding {
  final String fileId;
  final List<double> embedding;

  FileEmbedding({
    required this.fileId,
    required this.embedding,
  });

  factory FileEmbedding.fromDbMap(Map<String, dynamic> map) {
    final rawBlob = map['embeddinggemma2_embedding'] as Uint8List;
    return FileEmbedding(
      fileId: map['file_id'] as String,
      embedding: Float32List.view(rawBlob.buffer).toList(),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'file_id': fileId,
      'embeddinggemma2_embedding': Float32List.fromList(embedding).buffer.asUint8List(),
    };
  }
}
