import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/system_trash.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SystemTrash', () {
    const channel = MethodChannel('mydatastudio/system_trash');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('reports success and forwards the path', () async {
      String? sentPath;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'moveToTrash');
        sentPath = (call.arguments as Map)['path'] as String;
        return true;
      });

      expect(await SystemTrash().moveToTrash('/tmp/photo.jpg'), isTrue);
      expect(sentPath, '/tmp/photo.jpg');
    });

    // The whole point of the false. A platform with no implementation must
    // leave the file alone rather than fall back to deleting it — the user was
    // promised something recoverable, and silently destroying it instead is a
    // worse outcome than not removing it.
    test('returns false when no platform implements the channel', () async {
      // No handler registered at all is what a Windows or Linux runner looks
      // like today.
      expect(await SystemTrash().moveToTrash('/tmp/photo.jpg'), isFalse);
    });

    test('returns false when the platform refuses', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'trash_failed',
          message: 'Volume has no trash',
        );
      });
      expect(await SystemTrash().moveToTrash('/Volumes/net/x.jpg'), isFalse);
    });

    test('a null answer is treated as failure, not success', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await SystemTrash().moveToTrash('/tmp/photo.jpg'), isFalse);
    });
  });
}
