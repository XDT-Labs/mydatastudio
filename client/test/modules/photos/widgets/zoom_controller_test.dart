import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/widgets/viewer/zoom_controller.dart';

void main() {
  group('ZoomController Tests', () {
    late ZoomController controller;

    setUp(() {
      controller = ZoomController();
    });

    tearDown(() {
      controller.dispose();
    });

    test('initial values are correct', () {
      expect(controller.zoomLevel, 1.0);
      expect(ZoomController.minZoom, 0.5);
      expect(ZoomController.maxZoom, 3.0);
      expect(ZoomController.step, 0.25);
    });

    test('zoomIn increases zoom level and notifies listeners', () {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.zoomIn();
      expect(controller.zoomLevel, 1.25);
      expect(notifyCount, 1);

      controller.zoomIn();
      expect(controller.zoomLevel, 1.5);
      expect(notifyCount, 2);
    });

    test('zoomIn clamps at maxZoom', () {
      controller.zoomLevel = 2.9;
      controller.zoomIn();
      expect(controller.zoomLevel, 3.0);

      controller.zoomIn();
      expect(controller.zoomLevel, 3.0);
    });

    test('zoomOut decreases zoom level and notifies listeners', () {
      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.zoomOut();
      expect(controller.zoomLevel, 0.75);
      expect(notifyCount, 1);
    });

    test('zoomOut clamps at minZoom', () {
      controller.zoomLevel = 0.6;
      controller.zoomOut();
      expect(controller.zoomLevel, 0.5);

      controller.zoomOut();
      expect(controller.zoomLevel, 0.5);
    });

    test('reset restores zoom level to 1.0', () {
      controller.zoomIn();
      controller.zoomIn();
      expect(controller.zoomLevel, 1.5);

      int notifyCount = 0;
      controller.addListener(() => notifyCount++);

      controller.reset();
      expect(controller.zoomLevel, 1.0);
      expect(notifyCount, 1);
    });

    test('custom initial zoom clamps correctly', () {
      final custom = ZoomController(initialZoom: 5.0);
      expect(custom.zoomLevel, 3.0);
      custom.dispose();

      final customMin = ZoomController(initialZoom: 0.1);
      expect(customMin.zoomLevel, 0.5);
      customMin.dispose();
    });
  });
}
