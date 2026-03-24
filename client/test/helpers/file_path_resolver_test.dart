import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/helpers/file_path_resolver.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:uuid/uuid.dart';

Collection _makeCollection({
  String? localCopyPath,
  String path = '',
}) {
  return Collection(
    id: const Uuid().v4(),
    name: 'Test Collection',
    path: path,
    type: 'local',
    scanner: 'local_file',
    scanStatus: 'idle',
    needsReAuth: false,
    localCopyPath: localCopyPath,
  );
}

File _makeFile(String relativePath) {
  return File(
    id: 'col:$relativePath',
    collectionId: 'col',
    name: relativePath.split('/').last,
    path: relativePath,
    parent: relativePath.contains('/')
        ? relativePath.substring(0, relativePath.lastIndexOf('/'))
        : '',
    dateCreated: DateTime.now(),
    dateLastModified: DateTime.now(),
    lastScannedDate: DateTime.now(),
    isDeleted: false,
    size: 100,
    contentType: 'image/jpeg',
  );
}

void main() {
  group('FilePathResolver.absolute', () {
    test('returns absolute path by joining localCopyPath + relativePath', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = _makeFile('vacation/img.jpg');
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/Users/mike/Photos/vacation/img.jpg');
    });

    test('returns root path when relativePath is empty (root level)', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = _makeFile('');
      final result = FilePathResolver.absolute(file, col);
      // An empty relative path should return the root unchanged
      expect(result, '');
    });

    test('cloud gdrive:// path passes through unchanged', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = _makeFile('gdrive://some-file-id');
      final result = FilePathResolver.absolute(file, col);
      expect(result, 'gdrive://some-file-id');
    });

    test('already-absolute path passes through unchanged', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = _makeFile('/already/absolute/path.jpg');
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/already/absolute/path.jpg');
    });

    test('falls back to collection.path when localCopyPath is null', () {
      final col = _makeCollection(path: '/Users/mike/OldPath');
      final file = _makeFile('docs/report.pdf');
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/Users/mike/OldPath/docs/report.pdf');
    });

    test('handles deeply nested relative paths correctly', () {
      final col = _makeCollection(localCopyPath: '/data/my collection');
      final file = _makeFile('photos/2024/january/img.jpg');
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/data/my collection/photos/2024/january/img.jpg');
    });
  });

  group('FilePathResolver.absoluteFromPath', () {
    test('resolves path string directly', () {
      final col = _makeCollection(localCopyPath: '/Users/mike');
      final result = FilePathResolver.absoluteFromPath('docs/file.txt', col);
      expect(result, '/Users/mike/docs/file.txt');
    });

    test('empty string returns empty string', () {
      final col = _makeCollection(localCopyPath: '/Users/mike');
      final result = FilePathResolver.absoluteFromPath('', col);
      expect(result, '');
    });

    test('gdrive:// passthrough', () {
      final col = _makeCollection(localCopyPath: '/Users/mike');
      final result =
          FilePathResolver.absoluteFromPath('gdrive://abc123', col);
      expect(result, 'gdrive://abc123');
    });
  });
}
