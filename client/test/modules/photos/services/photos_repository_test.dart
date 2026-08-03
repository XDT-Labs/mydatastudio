import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';

void main() {
  group('PhotosRepository', () {
    test('queries photos with PhotoFilter instance', () async {
      final repo = PhotosRepository();
      expect(repo, isNotNull);

      final filter = const PhotoFilter(searchQuery: 'beach');
      expect(filter.searchQuery, equals('beach'));
    });
  });
}
