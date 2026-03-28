import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

/// In-memory TileProvider for tests — returns a 1x1 transparent PNG.
/// No HTTP requests are made. No dev dependency required.
///
/// flutter_map v7.0.2: override [getImage] (supportsCancelLoading defaults
/// to false, so this is the method the framework calls).
class FakeMemoryTileProvider extends TileProvider {
  static final Uint8List _transparentPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  );

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    return MemoryImage(_transparentPng);
  }
}
