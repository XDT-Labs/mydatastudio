import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/file_description_isolate.dart';

void main() {
  group('FileDescriptionIsolate.stripJsonFence', () {
    test('passes plain JSON through unchanged', () {
      const plain = '{"description": "A sunset over the ocean."}';
      expect(FileDescriptionIsolate.stripJsonFence(plain), plain);
    });

    test('strips a ```json ... ``` fence', () {
      const fenced = '```json\n{"description": "A sunset over the ocean."}\n```';
      expect(
        FileDescriptionIsolate.stripJsonFence(fenced),
        '{"description": "A sunset over the ocean."}',
      );
    });

    test('strips a bare ``` ... ``` fence with no language tag', () {
      const fenced = '```\n{"description": "A sunset over the ocean."}\n```';
      expect(
        FileDescriptionIsolate.stripJsonFence(fenced),
        '{"description": "A sunset over the ocean."}',
      );
    });

    test('trims surrounding whitespace regardless of fencing', () {
      const withWhitespace = '  \n{"description": "test"}\n  ';
      expect(
        FileDescriptionIsolate.stripJsonFence(withWhitespace),
        '{"description": "test"}',
      );
    });
  });
}
