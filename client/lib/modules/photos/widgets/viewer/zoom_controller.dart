import 'package:flutter/foundation.dart';

/// Manages zoom level state for media viewing.
class ZoomController extends ChangeNotifier {
  static const double minZoom = 0.5;
  static const double maxZoom = 3.0;
  static const double step = 0.25;

  double _zoomLevel;

  ZoomController({double initialZoom = 1.0})
    : _zoomLevel = initialZoom.clamp(minZoom, maxZoom).toDouble();

  double get zoomLevel => _zoomLevel;

  set zoomLevel(double value) {
    final clamped = value.clamp(minZoom, maxZoom).toDouble();
    if (_zoomLevel != clamped) {
      _zoomLevel = clamped;
      notifyListeners();
    }
  }

  void zoomIn() {
    zoomLevel = _zoomLevel + step;
  }

  void zoomOut() {
    zoomLevel = _zoomLevel - step;
  }

  void reset() {
    zoomLevel = 1.0;
  }
}
