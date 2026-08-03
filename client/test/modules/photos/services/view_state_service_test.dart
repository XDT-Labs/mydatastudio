import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';

void main() {
  group('ViewStateService', () {
    late ViewStateService service;

    setUp(() {
      service = ViewStateService.instance;
    });

    test('setViewMode changes viewMode', () {
      service.setViewMode(PhotoViewMode.timeline);
      expect(service.viewMode.value, equals(PhotoViewMode.timeline));
    });

    test('toggleInfo toggles isInfoOpen', () {
      bool initial = service.isInfoOpen.value;
      service.toggleInfo();
      expect(service.isInfoOpen.value, equals(!initial));
    });
  });
}
