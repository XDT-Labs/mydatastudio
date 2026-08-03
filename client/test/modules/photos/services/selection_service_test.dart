import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';

void main() {
  group('SelectionService', () {
    late SelectionService service;

    setUp(() {
      service = SelectionService.instance;
      service.deselectAll();
    });

    test('toggle adds and removes file id', () {
      service.toggle('123');
      expect(service.selectedIds.value, contains('123'));
      expect(service.isSelectionMode.value, isTrue);

      service.toggle('123');
      expect(service.selectedIds.value, isEmpty);
      expect(service.isSelectionMode.value, isFalse);
    });

    test('selectAll adds multiple ids', () {
      service.selectAll(['1', '2', '3']);
      expect(service.selectedIds.value, containsAll(['1', '2', '3']));
      expect(service.isSelectionMode.value, isTrue);
    });

    test('deselectAll clears all', () {
      service.selectAll(['1', '2', '3']);
      service.deselectAll();
      expect(service.selectedIds.value, isEmpty);
      expect(service.isSelectionMode.value, isFalse);
    });
  });
}
