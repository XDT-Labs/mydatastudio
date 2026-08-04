import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';

File _createTestFile(String id) => File(
      id: id,
      name: '$id.jpg',
      path: '/$id.jpg',
      parent: '/',
      dateCreated: DateTime.now(),
      dateLastModified: DateTime.now(),
      collectionId: 'col1',
      contentType: 'image/jpeg',
      size: 100,
      isDeleted: false,
    );

void main() {
  group('SelectionService', () {
    late SelectionService service;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
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

    test('selectRange handles forward, reversed ranges, and missing endpoint fallback', () {
      final files = [
        _createTestFile('f1'),
        _createTestFile('f2'),
        _createTestFile('f3'),
        _createTestFile('f4'),
      ];

      // Forward range: f1 to f3 -> includes f1, f2, f3
      service.selectRange('f1', 'f3', files);
      expect(service.selectedIds.value, equals({'f1', 'f2', 'f3'}));
      expect(service.isSelectionMode.value, isTrue);

      // Reversed range: f4 to f2 -> includes f2, f3, f4
      service.deselectAll();
      service.selectRange('f4', 'f2', files);
      expect(service.selectedIds.value, equals({'f2', 'f3', 'f4'}));

      // Missing endpoint fallback -> falls back to single selection of target
      service.deselectAll();
      service.selectRange('missing', 'f2', files);
      expect(service.selectedIds.value, equals({'f2'}));
    });

    test('handleCheckboxTap toggles item on normal tap and updates lastSelectedId', () {
      final files = [
        _createTestFile('f1'),
        _createTestFile('f2'),
        _createTestFile('f3'),
      ];

      service.handleCheckboxTap(files[0], files);
      expect(service.selectedIds.value, equals({'f1'}));
      expect(service.lastSelectedId, equals('f1'));

      service.handleCheckboxTap(files[2], files);
      expect(service.selectedIds.value, equals({'f1', 'f3'}));
      expect(service.lastSelectedId, equals('f3'));
    });
  });
}
