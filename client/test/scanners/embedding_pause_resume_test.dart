import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';

void main() {
  group('DatabaseManager embedding isolate pause & resume', () {
    test('pauseEmbeddingIsolates and resumeEmbeddingIsolates execute safely without error', () {
      expect(() => DatabaseManager.instance.pauseEmbeddingIsolates(), returnsNormally);
      expect(() => DatabaseManager.instance.resumeEmbeddingIsolates(), returnsNormally);
    });
  });
}
