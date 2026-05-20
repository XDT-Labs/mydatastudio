import 'dart:typed_data';

class FileEmbedding {
  final String fileId;
  final List<double> qwen3_8bEmbedding;

  FileEmbedding({
    required this.fileId,
    required this.qwen3_8bEmbedding,
  });

  factory FileEmbedding.fromDbMap(Map<String, dynamic> map) {
    final rawBlob = map['qwen3_8b_embedding'] as Uint8List;
    return FileEmbedding(
      fileId: map['file_id'] as String,
      qwen3_8bEmbedding: Float32List.view(rawBlob.buffer).toList(),
    );
  }

  Map<String, dynamic> toDbMap() {
    return {
      'file_id': fileId,
      'qwen3_8b_embedding': Float32List.fromList(qwen3_8bEmbedding).buffer.asUint8List(),
    };
  }
}
