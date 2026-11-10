import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/embedding_model.dart';

void main() {
  group('EmbeddingModel', () {
    test('declares EmbeddingGemma 2 configuration', () {
      expect(EmbeddingModel.modelName, 'google/embeddinggemma-2');
      expect(EmbeddingModel.dimension, 768);
      expect(EmbeddingModel.revision, 1);
      expect(EmbeddingModel.current, 'google/embeddinggemma-2@1');
    });
  });
}
