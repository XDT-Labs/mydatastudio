import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/custom_path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Records which method was called, so a delegation test can assert against
/// [_FakePathProviderPlatform.lastCall] instead of a real platform channel.
class _FakePathProviderPlatform extends PathProviderPlatform {
  String? lastCall;

  @override
  Future<String?> getTemporaryPath() async {
    lastCall = 'getTemporaryPath';
    return '/original/temp';
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    lastCall = 'getApplicationSupportPath';
    return '/original/support';
  }

  @override
  Future<String?> getLibraryPath() async {
    lastCall = 'getLibraryPath';
    return '/original/library';
  }

  @override
  Future<String?> getApplicationCachePath() async {
    lastCall = 'getApplicationCachePath';
    return '/original/cache';
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    lastCall = 'getApplicationDocumentsPath';
    return '/original/documents';
  }

  @override
  Future<String?> getExternalStoragePath() async {
    lastCall = 'getExternalStoragePath';
    return '/original/external';
  }

  @override
  Future<List<String>?> getExternalCachePaths() async {
    lastCall = 'getExternalCachePaths';
    return ['/original/external-cache'];
  }

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async {
    lastCall = 'getExternalStoragePaths';
    return ['/original/external-storage'];
  }

  @override
  Future<String?> getDownloadsPath() async {
    lastCall = 'getDownloadsPath';
    return '/original/downloads';
  }
}

void main() {
  group('CustomPathProviderPlatform', () {
    late _FakePathProviderPlatform original;
    late CustomPathProviderPlatform custom;

    setUp(() {
      original = _FakePathProviderPlatform();
      custom = CustomPathProviderPlatform(original, '/custom/support');
    });

    test('getApplicationSupportPath returns the custom override, not the original', () async {
      final path = await custom.getApplicationSupportPath();
      expect(path, '/custom/support');
      expect(original.lastCall, isNull, reason: 'must not touch the original platform at all');
    });

    // Regression test: getApplicationCachePath had no override, so it fell
    // through to PathProviderPlatform's base implementation, which throws
    // UnimplementedError — this is what flutter_map's disk tile cache hit.
    test('every other path getter delegates to the original platform', () async {
      expect(await custom.getTemporaryPath(), '/original/temp');
      expect(original.lastCall, 'getTemporaryPath');

      expect(await custom.getLibraryPath(), '/original/library');
      expect(original.lastCall, 'getLibraryPath');

      expect(await custom.getApplicationCachePath(), '/original/cache');
      expect(original.lastCall, 'getApplicationCachePath');

      expect(await custom.getApplicationDocumentsPath(), '/original/documents');
      expect(original.lastCall, 'getApplicationDocumentsPath');

      expect(await custom.getExternalStoragePath(), '/original/external');
      expect(original.lastCall, 'getExternalStoragePath');

      expect(await custom.getExternalCachePaths(), ['/original/external-cache']);
      expect(original.lastCall, 'getExternalCachePaths');

      expect(await custom.getExternalStoragePaths(), ['/original/external-storage']);
      expect(original.lastCall, 'getExternalStoragePaths');

      expect(await custom.getDownloadsPath(), '/original/downloads');
      expect(original.lastCall, 'getDownloadsPath');
    });
  });
}
