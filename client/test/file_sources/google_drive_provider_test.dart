import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mocktail/mocktail.dart';
import 'package:mydatatools/file_sources/file_source_file.dart';
import 'package:mydatatools/file_sources/google_drive/google_drive_provider.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

class MockDriveApi extends Mock implements drive.DriveApi {}
class MockFilesResource extends Mock implements drive.FilesResource {}

/// A testable version of GoogleDriveProvider that allows injecting a mock API.
class MockGoogleDriveProvider extends GoogleDriveProvider {
  final drive.DriveApi _mockApi;
  const MockGoogleDriveProvider(this._mockApi);

  @override
  Future<drive.DriveApi> buildApi(Collection collection) async => _mockApi;
}

void main() {
  const provider = GoogleDriveProvider();

  setUpAll(() {
    registerFallbackValue(drive.File());
  });

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
        provider.isGoogleNativeFormat(
          'application/vnd.google-apps.spreadsheet',
        ),
        isTrue,
      );
    });

    test('returns true for Google Slides', () {
      expect(
        provider.isGoogleNativeFormat(
          'application/vnd.google-apps.presentation',
        ),
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
      expect(
        result.webViewLink,
        equals('https://drive.google.com/file/d/abc123/view'),
      );
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
      final driveFile =
          drive.File()
            ..id = 'x'
            ..mimeType = 'application/pdf';
      // name intentionally not set

      final result = provider.toFileSourceFile(driveFile, parentId: 'p');
      expect(result.name, equals('Untitled'));
    });

    test('uses application/octet-stream when mimeType is null', () {
      final driveFile =
          drive.File()
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
  // API dependent tests (using mocks)
  // ---------------------------------------------------------------------------

  group('GoogleDriveProvider (mocked API)', () {
    late MockDriveApi mockApi;
    late MockFilesResource mockFiles;
    late MockGoogleDriveProvider testProvider;
    late Collection collection;

    setUp(() {
      mockApi = MockDriveApi();
      mockFiles = MockFilesResource();
      testProvider = MockGoogleDriveProvider(mockApi);
      
      when(() => mockApi.files).thenReturn(mockFiles);

      collection = Collection(
        id: const Uuid().v4(),
        name: 'Gdrive',
        path: 'root',
        type: 'file',
        scanner: 'file.gdrive',
        scanStatus: 'pending',
        needsReAuth: false,
      );
    });

    test('listFolder calls files.list and maps results', () async {
      final fileList = drive.FileList()
        ..files = [
          drive.File()
            ..id = 'f1'
            ..name = 'file1.txt'
            ..mimeType = 'text/plain',
          drive.File()
            ..id = 'd1'
            ..name = 'Folder1'
            ..mimeType = 'application/vnd.google-apps.folder',
        ];

      when(() => mockFiles.list(
            q: any(named: 'q'),
            $fields: any(named: '\$fields'),
            pageToken: any(named: 'pageToken'),
            pageSize: any(named: 'pageSize'),
            orderBy: any(named: 'orderBy'),
          )).thenAnswer((_) async => fileList);

      final results = await testProvider.listFolder(collection);

      expect(results.length, equals(2));
      expect(results[0].name, equals('file1.txt'));
      expect(results[1].isFolder, isTrue);
      
      verify(() => mockFiles.list(
            q: "'root' in parents and trashed = false",
            $fields: any(named: '\$fields'),
            pageSize: 200,
            orderBy: 'folder, name',
          )).called(1);
    });

    test('deleteFile calls files.update with trashed=true', () async {
      final file = FileSourceFile(
        id: 'f123',
        name: 'Delete Me',
        mimeType: 'text/plain',
        isFolder: false,
      );

      when(() => mockFiles.update(
            any(),
            any(),
          )).thenAnswer((_) async => drive.File());

      final success = await testProvider.deleteFile(collection, file);

      expect(success, isTrue);
      
      final capturedFile = verify(() => mockFiles.update(
            captureAny(),
            'f123',
          )).captured.first as drive.File;
      
      expect(capturedFile.trashed, isTrue);
    });

    test('deleteFile returns false on API error', () async {
      final file = FileSourceFile(
        id: 'f123',
        name: 'Error Me',
        mimeType: 'text/plain',
        isFolder: false,
      );

      when(() => mockFiles.update(any(), any()))
          .thenThrow(Exception('API Error'));

      final success = await testProvider.deleteFile(collection, file);
      expect(success, isFalse);
    });
  });
}
