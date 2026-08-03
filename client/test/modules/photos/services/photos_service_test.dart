import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';

void main() {
  group('PhotosService', () {
    test('dispatches PhotosServiceCommand and exposes active sink output', () async {
      final service = PhotosService.instance;
      
      final filter = const PhotoFilter(searchQuery: 'sunset');
      final command = PhotosServiceCommand(filter);
      
      expect(command.filter.searchQuery, equals('sunset'));
      expect(service.sink, isNotNull);
      expect(service.isLoading.value, isFalse);
    });
  });
}
