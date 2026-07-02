import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/python_manager.dart';

void main() {
  group('PythonManager urlRegex tests', () {
    late PythonManager manager;

    setUp(() async {
      manager = await PythonManager.forAppSupport();
    });

    test('matches valid loopback IPv4 URL', () {
      const line = 'INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), equals('http://127.0.0.1:8000'));
    });

    test('matches valid loopback localhost URL', () {
      const line = 'INFO:     Uvicorn running on http://localhost:8080 (Press CTRL+C to quit)';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), equals('http://localhost:8080'));
    });

    test('does not match non-loopback http URL', () {
      const line = 'Downloading from http://example.com/file.zip';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match https Hugging Face URL', () {
      const line = 'Downloading from https://huggingface.co/gpt2/resolve/main/model.gguf';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match GCS downloader URL', () {
      const line = 'Downloading from https://gcs-file-downloader-10805446439.us-central1.run.app';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match loopback with https', () {
      const line = 'Secure local server: https://127.0.0.1:8443';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match domain containing loopback name as substring', () {
      const line = 'Visit http://127.0.0.1.com:8000 or http://localhost.company.com:80';
      final match = manager.urlRegex.firstMatch(line);
      expect(match, isNull);
    });
  });
}
