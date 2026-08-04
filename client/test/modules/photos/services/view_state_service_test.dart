import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';

File _dummyFile() => File(
      id: 'file-1',
      name: 'test.jpg',
      path: '/test.jpg',
      parent: '/',
      dateCreated: DateTime.now(),
      dateLastModified: DateTime.now(),
      collectionId: 'col1',
      contentType: 'image/jpeg',
      size: 100,
      isDeleted: false,
    );

void main() {
  group('ViewStateService', () {
    late ViewStateService service;

    setUp(() {
      service = ViewStateService.instance;
      SelectionService.instance.deselectAll();
      service.closeLightboxAndInfo();
    });

    test('setViewMode changes viewMode', () {
      service.setViewMode(PhotoViewMode.list);
      expect(service.viewMode.value, equals(PhotoViewMode.list));
    });

    test('toggleInfo toggles isInfoOpen', () {
      bool initial = service.isInfoOpen.value;
      service.toggleInfo();
      expect(service.isInfoOpen.value, equals(!initial));
    });

    test('updateFilter closes lightbox/info panels and clears selection', () {
      SelectionService.instance.toggle('file-1');
      service.isInfoOpen.add(true);
      service.setLightboxMedia(_dummyFile());

      expect(SelectionService.instance.selectedIds.value, contains('file-1'));
      expect(service.isInfoOpen.value, isTrue);
      expect(service.lightboxMedia.value, isNotNull);

      service.updateFilter(const PhotoFilter(searchQuery: 'new search'));

      expect(SelectionService.instance.selectedIds.value, isEmpty);
      expect(service.isInfoOpen.value, isFalse);
      expect(service.lightboxMedia.value, isNull);
    });

    test('setActiveNav closes lightbox/info panels and clears selection', () {
      SelectionService.instance.toggle('file-1');
      service.isInfoOpen.add(true);
      service.setLightboxMedia(_dummyFile());

      service.setActiveNav('album-123');

      expect(SelectionService.instance.selectedIds.value, isEmpty);
      expect(service.isInfoOpen.value, isFalse);
      expect(service.lightboxMedia.value, isNull);
      expect(service.activeNav.value, equals('album-123'));
    });
  });
}
