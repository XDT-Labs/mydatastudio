import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';

void main() {
  group('BatchActionService', () {
    test('deleteSelected deselects all items upon completion', () async {
      final service = BatchActionService.instance;
      SelectionService.instance.selectAll(['f1', 'f2']);
      expect(SelectionService.instance.selectedIds.value, containsAll(['f1', 'f2']));

      await service.deleteSelected({'f1', 'f2'});

      expect(SelectionService.instance.selectedIds.value, isEmpty);
    });

    test('addToAlbum deselects all items upon completion', () async {
      final service = BatchActionService.instance;
      SelectionService.instance.selectAll(['f1']);
      expect(SelectionService.instance.selectedIds.value, contains('f1'));

      await service.addToAlbum({'f1'}, 'album-1');

      expect(SelectionService.instance.selectedIds.value, isEmpty);
    });
  });
}
