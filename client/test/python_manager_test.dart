import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/python_manager.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // The models are multi-gigabyte downloads and an app upgrade deletes the
  // aiserver directory they used to live in. These tests exist to make that
  // deletion survivable: if the migration stops moving models clear, a user
  // silently loses ~10 GB and has to re-download on every release.
  group('PythonManager.migrateModelsDir', () {
    late Directory support;

    setUp(() {
      support = Directory.systemTemp.createTempSync('mds_models_migrate');
    });

    tearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    String legacyPath(String name) =>
        p.join(support.path, 'aiserver', 'models', name);
    String targetPath(String name) =>
        p.join(PythonManager.modelsDirFor(support.path), name);

    test('moves downloads out of aiserver/ and removes the old directory', () {
      Directory(p.join(support.path, 'aiserver', 'models')).createSync(
        recursive: true,
      );
      File(legacyPath('gemma.gguf')).writeAsStringSync('weights');
      Directory(legacyPath('Qwen-local')).createSync();
      File(p.join(legacyPath('Qwen-local'), 'model.safetensors'))
          .writeAsStringSync('more weights');

      PythonManager.migrateModelsDir(support.path);

      expect(File(targetPath('gemma.gguf')).readAsStringSync(), 'weights');
      expect(
        File(
          p.join(targetPath('Qwen-local'), 'model.safetensors'),
        ).readAsStringSync(),
        'more weights',
      );
      expect(
        Directory(p.join(support.path, 'aiserver', 'models')).existsSync(),
        isFalse,
        reason: 'the old directory must go, or the next upgrade migrates again',
      );
    });

    test('is a no-op when there is nothing to migrate', () {
      Directory(p.join(support.path, 'aiserver')).createSync(recursive: true);

      PythonManager.migrateModelsDir(support.path);

      // Must not create an empty models dir as a side effect — a later
      // "have the models been downloaded?" check keys off what is on disk.
      expect(
        Directory(PythonManager.modelsDirFor(support.path)).existsSync(),
        isFalse,
      );
    });

    test('keeps the in-use copy when the same model exists in both places', () {
      // Reachable when an older build runs after the migration and
      // re-downloads into the old path. The copy already at the destination is
      // the one the app has been loading, so it must win.
      Directory(p.join(support.path, 'aiserver', 'models')).createSync(
        recursive: true,
      );
      Directory(PythonManager.modelsDirFor(support.path)).createSync();
      File(legacyPath('gemma.gguf')).writeAsStringSync('stale');
      File(targetPath('gemma.gguf')).writeAsStringSync('in use');
      File(legacyPath('extra.gguf')).writeAsStringSync('only in legacy');

      PythonManager.migrateModelsDir(support.path);

      expect(File(targetPath('gemma.gguf')).readAsStringSync(), 'in use');
      expect(
        File(targetPath('extra.gguf')).readAsStringSync(),
        'only in legacy',
        reason: 'a colliding name must not stop the rest from migrating',
      );
      expect(
        Directory(p.join(support.path, 'aiserver', 'models')).existsSync(),
        isFalse,
      );
    });
  });

  // Before the version stamp, an existing aiserver/ directory was reason
  // enough to skip extraction, so a DMG upgrade left the previous release's
  // Python service in place and the new client talked to it. These tests pin
  // the replacement behaviour and the ordering it depends on.
  group('PythonManager.ensureAiserverUnzipped version stamp', () {
    late Directory support;
    late PythonManager manager;

    // One support directory for the whole group: DatabaseManager caches the
    // resolved Application Support path in a static for the life of the
    // isolate, so a per-test directory would be ignored after the first test
    // — and with the fixture zip missing from the cached path, the candidate
    // search would fall through to the repo's real 250 MB bundle.
    setUpAll(() async {
      support = Directory.systemTemp.createTempSync('mds_aiserver_stamp');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (MethodCall call) async => support.path,
          );
      manager = await PythonManager.forAppSupport();
    });

    setUp(() {
      for (final entity in support.listSync()) {
        entity.deleteSync(recursive: true);
      }
    });

    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null,
          );
      if (support.existsSync()) support.deleteSync(recursive: true);
    });

    /// Build the zip that ships inside the .app, standing in for the real
    /// ~250 MB PyInstaller bundle. `<support>/aiserver-macos.zip` is the first
    /// path ensureAiserverUnzipped() searches.
    void writeBundledZip(String binaryContents) {
      final staging = Directory(
        p.join(support.path, 'staging', 'aiserver'),
      )..createSync(recursive: true);
      File(p.join(staging.path, 'aiserver')).writeAsStringSync(binaryContents);
      final result = Process.runSync('ditto', [
        '-c',
        '-k',
        '--sequesterRsrc',
        staging.path,
        p.join(support.path, 'aiserver-macos.zip'),
      ]);
      expect(result.exitCode, 0, reason: 'ditto failed: ${result.stderr}');
      staging.parent.deleteSync(recursive: true);
    }

    String installedBinary() =>
        File(p.join(support.path, 'aiserver', 'aiserver')).readAsStringSync();

    String? stamp() {
      final f = File(
        p.join(support.path, 'aiserver', PythonManager.versionStampName),
      );
      return f.existsSync() ? f.readAsStringSync().trim() : null;
    }

    test('extracts and stamps on a first install', () async {
      writeBundledZip('v1 binary');

      await manager.ensureAiserverUnzipped(appVersion: '1.0.1+2');

      expect(installedBinary(), 'v1 binary');
      expect(stamp(), '1.0.1+2');
    });

    test('replaces an install left by a previous app version', () async {
      writeBundledZip('v1 binary');
      await manager.ensureAiserverUnzipped(appVersion: '1.0.1+2');

      writeBundledZip('v2 binary');
      await manager.ensureAiserverUnzipped(appVersion: '1.1.0+3');

      expect(
        installedBinary(),
        'v2 binary',
        reason: 'a new client must not run against the old release\'s server',
      );
      expect(stamp(), '1.1.0+3');
    });

    test('replaces an unstamped install from before this change', () async {
      // What every existing user has on disk: an aiserver directory with no
      // stamp in it.
      final dir = Directory(p.join(support.path, 'aiserver'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'aiserver')).writeAsStringSync('legacy binary');
      writeBundledZip('v2 binary');

      await manager.ensureAiserverUnzipped(appVersion: '1.1.0+3');

      expect(installedBinary(), 'v2 binary');
      expect(stamp(), '1.1.0+3');
    });

    test('leaves a current install alone', () async {
      writeBundledZip('v1 binary');
      await manager.ensureAiserverUnzipped(appVersion: '1.0.1+2');

      // A re-extract would overwrite this; skipping preserves it.
      File(
        p.join(support.path, 'aiserver', 'aiserver'),
      ).writeAsStringSync('untouched');
      await manager.ensureAiserverUnzipped(appVersion: '1.0.1+2');

      expect(installedBinary(), 'untouched');
    });

    test('preserves downloaded models across an upgrade', () async {
      // The whole point of moving models out of aiserver/: the upgrade path
      // deletes that directory wholesale.
      writeBundledZip('v1 binary');
      await manager.ensureAiserverUnzipped(appVersion: '1.0.1+2');
      final models = Directory(PythonManager.modelsDirFor(support.path))
        ..createSync(recursive: true);
      File(p.join(models.path, 'gemma.gguf')).writeAsStringSync('weights');

      writeBundledZip('v2 binary');
      await manager.ensureAiserverUnzipped(appVersion: '1.1.0+3');

      expect(installedBinary(), 'v2 binary');
      expect(
        File(p.join(models.path, 'gemma.gguf')).readAsStringSync(),
        'weights',
      );
    });

    test('migrates legacy in-aiserver models before deleting the dir',
        () async {
      // Upgrading straight from a build that kept models inside aiserver/:
      // the migration has to run before the delete or the download is gone.
      final legacyModels = Directory(
        p.join(support.path, 'aiserver', 'models'),
      )..createSync(recursive: true);
      File(
        p.join(legacyModels.path, 'gemma.gguf'),
      ).writeAsStringSync('weights');
      File(
        p.join(support.path, 'aiserver', 'aiserver'),
      ).writeAsStringSync('legacy binary');
      writeBundledZip('v2 binary');

      await manager.ensureAiserverUnzipped(appVersion: '1.1.0+3');

      expect(installedBinary(), 'v2 binary');
      expect(
        File(
          p.join(PythonManager.modelsDirFor(support.path), 'gemma.gguf'),
        ).readAsStringSync(),
        'weights',
      );
    });
  }, skip: !Platform.isMacOS ? 'needs macOS ditto to build the fixture' : null);
}
