import 'package:mydatastudio/file_sources/file_source_file.dart';
import 'package:test/test.dart';

void main() {
  group('FileSourceFile', () {
    const localFile = FileSourceFile(
      id: '/Users/test/documents/report.pdf',
      name: 'report.pdf',
      parentId: '/Users/test/documents',
      mimeType: 'application/pdf',
      size: 1024,
      isFolder: false,
    );

    const driveFile = FileSourceFile(
      id: '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgVE2upms',
      name: 'Spreadsheet',
      parentId: 'root',
      mimeType: 'application/vnd.google-apps.spreadsheet',
      isFolder: false,
      webViewLink: 'https://docs.google.com/spreadsheets/d/1BxiMVs0X',
    );

    const folder = FileSourceFile(
      id: '/Users/test/documents',
      name: 'documents',
      mimeType: 'inode/directory',
      isFolder: true,
    );

    test('equality is based on id only', () {
      const same = FileSourceFile(
        id: '/Users/test/documents/report.pdf',
        name: 'different name',
        mimeType: 'text/plain',
        isFolder: false,
      );
      expect(localFile, equals(same));
    });

    test('different ids are not equal', () {
      expect(localFile, isNot(equals(driveFile)));
    });

    test('hashCode matches equality contract', () {
      const duplicate = FileSourceFile(
        id: '/Users/test/documents/report.pdf',
        name: 'report.pdf',
        mimeType: 'application/pdf',
        isFolder: false,
      );
      expect(localFile.hashCode, equals(duplicate.hashCode));
    });

    test('isFolder is true for directory entries', () {
      expect(folder.isFolder, isTrue);
      expect(localFile.isFolder, isFalse);
    });

    test('optional fields default to null', () {
      expect(localFile.createdAt, isNull);
      expect(localFile.modifiedAt, isNull);
      expect(localFile.webViewLink, isNull);
      expect(localFile.thumbnailLink, isNull);
    });

    test('Drive file carries webViewLink', () {
      expect(driveFile.webViewLink, isNotNull);
      expect(driveFile.webViewLink, startsWith('https://'));
    });

    test('toString contains id and name', () {
      final s = localFile.toString();
      expect(s, contains('report.pdf'));
      expect(s, contains('/Users/test/documents/report.pdf'));
    });
  });
}
