import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';

void main() {
  group('PhotosRepository', () {
    test('instance exists', () {
      final repo = PhotosRepository();
      expect(repo, isNotNull);
    });
  });
}
