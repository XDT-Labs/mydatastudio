import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/helpers/file_path_resolver.dart';
import 'package:mydatastudio/models/tables/collection.dart';

import 'file_fixture.dart';

Collection _makeCollection({String? localCopyPath, String path = ''}) {
  return makeTestCollection(path: path, localCopyPath: localCopyPath);
}

void main() {
  group('FilePathResolver.absolute', () {
    test('returns absolute path by joining localCopyPath + relativePath', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = makeTestFile(
        path: 'vacation/img.jpg',
        parent: 'vacation',
        name: 'img.jpg',
      );
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/Users/mike/Photos/vacation/img.jpg');
    });

    test('returns root path when relativePath is empty (root level)', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = makeTestFile(path: '', parent: '', name: '');
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/Users/mike/Photos');
    });

    test('cloud gdrive:// path passes through unchanged', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = makeTestFile(
        path: 'gdrive://some-file-id',
        parent: '',
        name: 'some-file-id',
      );
      final result = FilePathResolver.absolute(file, col);
      expect(result, 'gdrive://some-file-id');
    });

    test('already-absolute path passes through unchanged', () {
      final col = _makeCollection(localCopyPath: '/Users/mike/Photos');
      final file = makeTestFile(
        path: '/already/absolute/path.jpg',
        parent: '/already/absolute',
        name: 'path.jpg',
      );
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/already/absolute/path.jpg');
    });

    test('falls back to collection.path when localCopyPath is null', () {
      final col = _makeCollection(path: '/Users/mike/OldPath');
      final file = makeTestFile(
        path: 'docs/report.pdf',
        parent: 'docs',
        name: 'report.pdf',
      );
      final result = FilePathResolver.absolute(file, col);
      expect(result, '/Users/mike/OldPath/docs/report.pdf');
    });

    test('handles deeply nested relative paths correctly', () {
      final col = _makeCollection(localCopyPath: '/data/my collection');
      final file = makeTestFile(
        path: 'photos/2024/january/img.jpg',
        parent: 'photos/2024/january',
        name: 'img.jpg',
      );
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

    test('empty string returns root path', () {
      final col = _makeCollection(localCopyPath: '/Users/mike');
      final result = FilePathResolver.absoluteFromPath('', col);
      expect(result, '/Users/mike');
    });

    test('gdrive:// passthrough', () {
      final col = _makeCollection(localCopyPath: '/Users/mike');
      final result = FilePathResolver.absoluteFromPath('gdrive://abc123', col);
      expect(result, 'gdrive://abc123');
    });
  });
}
