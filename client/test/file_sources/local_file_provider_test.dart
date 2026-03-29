import 'dart:io' as io;
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/file_sources/file_source_file.dart';
import 'package:mydatatools/file_sources/local/local_file_provider.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  late io.Directory tempDir;
  const provider = LocalFileProvider();

  setUp(() async {
    tempDir = await io.Directory.systemTemp.createTemp('local_provider_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Collection makeCollection(String path) => Collection(
        id: const Uuid().v4(),
        name: 'Test Local',
        path: path,
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
        scanStatus: 'pending',
        needsReAuth: false,
      );

  group('LocalFileProvider', () {
    test('metadata is correct', () {
      expect(provider.providerKey, equals('local'));
      expect(provider.scannerType, equals(AppConstants.scannerFileLocal));
    });

    group('listFolder', () {
      test('returns empty list for non-existent directory', () async {
        final collection = makeCollection(p.join(tempDir.path, 'non_existent'));
        final results = await provider.listFolder(collection);
        expect(results, isEmpty);
      });

      test('lists files and directories correctly', () async {
        // Setup: 1 file, 1 dir, 1 hidden file
        await io.File(p.join(tempDir.path, 'test.txt')).create();
        await io.File(p.join(tempDir.path, 'image.jpg')).create();
        await io.Directory(p.join(tempDir.path, 'subdir')).create();
        await io.File(p.join(tempDir.path, '.hidden')).create();

        final collection = makeCollection(tempDir.path);
        final results = await provider.listFolder(collection);

        expect(results.length, equals(3)); // text, image, subdir (hidden ignored)
        
        final txtFile = results.firstWhere((f) => f.name == 'test.txt');
        expect(txtFile.isFolder, isFalse);
        expect(txtFile.mimeType, equals('text/plain'));
        expect(txtFile.id, equals(p.join(tempDir.path, 'test.txt')));

        final imgFile = results.firstWhere((f) => f.name == 'image.jpg');
        expect(imgFile.mimeType, equals('image/jpeg'));

        final subdir = results.firstWhere((f) => f.name == 'subdir');
        expect(subdir.isFolder, isTrue);
        expect(subdir.mimeType, equals('inode/directory'));
      });

      test('respects folderId override', () async {
        final subPath = p.join(tempDir.path, 'subdir');
        await io.Directory(subPath).create();
        await io.File(p.join(subPath, 'inner.txt')).create();

        final collection = makeCollection(tempDir.path);
        final results = await provider.listFolder(collection, folderId: subPath);

        expect(results.length, equals(1));
        expect(results.first.name, equals('inner.txt'));
      });
    });

    group('actions', () {
      test('downloadFile copies file if destPath differs', () async {
        final sourceFile = io.File(p.join(tempDir.path, 'source.txt'));
        await sourceFile.writeAsString('hello');
        
        final destPath = p.join(tempDir.path, 'dest.txt');
        final collection = makeCollection(tempDir.path);
        
        final result = await provider.downloadFile(
          collection,
          _makeFileSource(sourceFile.path),
          destPath,
        );

        expect(result.path, equals(destPath));
        expect(await io.File(destPath).exists(), isTrue);
        expect(await io.File(destPath).readAsString(), equals('hello'));
      });

      test('downloadFile returns source if destPath is same', () async {
        final sourceFile = io.File(p.join(tempDir.path, 'source.txt'));
        await sourceFile.create();
        
        final collection = makeCollection(tempDir.path);
        final result = await provider.downloadFile(
          collection,
          _makeFileSource(sourceFile.path),
          sourceFile.path,
        );

        expect(result.path, equals(sourceFile.path));
      });

      test('deleteFile removes file from disk', () async {
        final file = io.File(p.join(tempDir.path, 'to_delete.txt'));
        await file.create();
        
        final collection = makeCollection(tempDir.path);
        final success = await provider.deleteFile(
          collection,
          _makeFileSource(file.path),
        );

        expect(success, isTrue);
        expect(await file.exists(), isFalse);
      });

      test('deleteFile returns false if file does not exist', () async {
        final collection = makeCollection(tempDir.path);
        final success = await provider.deleteFile(
          collection,
          _makeFileSource(p.join(tempDir.path, 'missing.txt')),
        );

        expect(success, isFalse);
      });
    });

    group('MIME type mapping', () {
      test('maps common extensions correctly', () async {
        // Since _mimeTypeFromName is private, we test it via listFolder
        final extensions = {
          'pdf': 'application/pdf',
          'png': 'image/png',
          'mp4': 'video/mp4',
          'zip': 'application/zip',
          'unknown': 'application/octet-stream',
        };

        for (final ext in extensions.keys) {
          await io.File(p.join(tempDir.path, 'test.$ext')).create();
        }

        final collection = makeCollection(tempDir.path);
        final results = await provider.listFolder(collection);

        for (final entry in results) {
          final ext = p.extension(entry.name).replaceFirst('.', '');
          if (extensions.containsKey(ext)) {
            expect(entry.mimeType, equals(extensions[ext]), reason: 'Failed for .$ext');
          }
        }
      });
    });
  });
}

FileSourceFile _makeFileSource(String path) {
  return FileSourceFile(
    id: path,
    name: p.basename(path),
    mimeType: 'text/plain',
    isFolder: false,
  );
}
