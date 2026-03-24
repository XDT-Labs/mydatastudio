import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mydatatools/file_sources/google_drive/google_drive_provider.dart';
import 'package:test/test.dart';

void main() {
  const provider = GoogleDriveProvider();

  // ---------------------------------------------------------------------------
  // Provider metadata
  // ---------------------------------------------------------------------------

  group('GoogleDriveProvider metadata', () {
    test('providerKey is gdrive', () {
      expect(provider.providerKey, equals('gdrive'));
    });

    test('scannerType matches AppConstants', () {
      expect(provider.scannerType, equals('file.gdrive'));
    });

    test('displayName is Google Drive', () {
      expect(provider.displayName, equals('Google Drive'));
    });
  });

  // ---------------------------------------------------------------------------
  // isGoogleNativeFormat
  // ---------------------------------------------------------------------------

  group('GoogleDriveProvider.isGoogleNativeFormat', () {
    test('returns true for Google Docs', () {
      expect(
        provider.isGoogleNativeFormat('application/vnd.google-apps.document'),
        isTrue,
      );
    });

    test('returns true for Google Sheets', () {
      expect(
        provider.isGoogleNativeFormat('application/vnd.google-apps.spreadsheet'),
        isTrue,
      );
    });

    test('returns true for Google Slides', () {
      expect(
        provider.isGoogleNativeFormat('application/vnd.google-apps.presentation'),
        isTrue,
      );
    });

    test('returns false for Drive folders', () {
      expect(
        provider.isGoogleNativeFormat('application/vnd.google-apps.folder'),
        isFalse,
      );
    });

    test('returns false for regular JPEG', () {
      expect(provider.isGoogleNativeFormat('image/jpeg'), isFalse);
    });

    test('returns false for PDF', () {
      expect(provider.isGoogleNativeFormat('application/pdf'), isFalse);
    });

    test('returns false for MP4', () {
      expect(provider.isGoogleNativeFormat('video/mp4'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // toFileSourceFile
  // ---------------------------------------------------------------------------

  group('GoogleDriveProvider.toFileSourceFile', () {
    final created = DateTime(2024, 6, 1);
    final modified = DateTime(2024, 6, 15);

    drive.File makeDriveFile({
      required String id,
      required String name,
      required String mimeType,
      String? size,
      String? webViewLink,
      String? thumbnailLink,
    }) {
      return drive.File()
        ..id = id
        ..name = name
        ..mimeType = mimeType
        ..size = size
        ..createdTime = created
        ..modifiedTime = modified
        ..webViewLink = webViewLink
        ..thumbnailLink = thumbnailLink;
    }

    test('maps a regular file correctly', () {
      final driveFile = makeDriveFile(
        id: 'abc123',
        name: 'photo.jpg',
        mimeType: 'image/jpeg',
        size: '204800',
        webViewLink: 'https://drive.google.com/file/d/abc123/view',
      );

      final result = provider.toFileSourceFile(driveFile, parentId: 'rootId');

      expect(result.id, equals('abc123'));
      expect(result.name, equals('photo.jpg'));
      expect(result.parentId, equals('rootId'));
      expect(result.mimeType, equals('image/jpeg'));
      expect(result.size, equals(204800));
      expect(result.createdAt, equals(created));
      expect(result.modifiedAt, equals(modified));
      expect(result.isFolder, isFalse);
      expect(result.webViewLink, equals('https://drive.google.com/file/d/abc123/view'));
    });

    test('maps a folder correctly — isFolder true, size null', () {
      final driveFolder = makeDriveFile(
        id: 'folderXYZ',
        name: 'Photos',
        mimeType: 'application/vnd.google-apps.folder',
        size: null,
      );

      final result = provider.toFileSourceFile(driveFolder, parentId: 'root');

      expect(result.isFolder, isTrue);
      expect(result.size, isNull);
      expect(result.mimeType, equals('application/vnd.google-apps.folder'));
    });

    test('uses Untitled when drive file has no name', () {
      final driveFile = drive.File()
        ..id = 'x'
        ..mimeType = 'application/pdf';
      // name intentionally not set

      final result = provider.toFileSourceFile(driveFile, parentId: 'p');
      expect(result.name, equals('Untitled'));
    });

    test('uses application/octet-stream when mimeType is null', () {
      final driveFile = drive.File()
        ..id = 'x'
        ..name = 'binary.bin';
      // mimeType intentionally not set

      final result = provider.toFileSourceFile(driveFile, parentId: 'p');
      expect(result.mimeType, equals('application/octet-stream'));
    });

    test('size is null when drive file size string is null', () {
      final driveFile = makeDriveFile(
        id: 'f1',
        name: 'doc',
        mimeType: 'application/vnd.google-apps.document',
        size: null,
      );

      final result = provider.toFileSourceFile(driveFile, parentId: 'p');
      expect(result.size, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // downloadFile — native format guard
  // ---------------------------------------------------------------------------

  group('GoogleDriveProvider.downloadFile — native format guard', () {
    // We only test the guard here (no network needed). Network-dependent paths
    // are covered by integration/widget tests that inject a mock API client.

    test('native format guard identifies Google Docs mimeType', () async {
      const nativeFile = _NativeFileSourceFile();

      expect(
        provider.isGoogleNativeFormat(nativeFile.mimeType),
        isTrue,
        reason: 'The native format guard should identify this MIME type',
      );
    });
  });
}

/// Minimal inline stub for testing the guard condition.
class _NativeFileSourceFile {
  const _NativeFileSourceFile();
  String get mimeType => 'application/vnd.google-apps.document';
}
