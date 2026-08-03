import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';

void main() {
  group('BatchActionService', () {
    test('instance exists', () {
      final service = BatchActionService.instance;
      expect(service, isNotNull);
    });
  });
}
