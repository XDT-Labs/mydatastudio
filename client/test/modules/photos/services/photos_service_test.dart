import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';

void main() {
  group('PhotosService', () {
    test('instance exists and handles commands', () {
      final service = PhotosService.instance;
      expect(service, isNotNull);
      
      final filter = const PhotoFilter(searchQuery: 'test');
      final command = PhotosServiceCommand(filter);
      expect(command.filter.searchQuery, 'test');
    });
  });
}
