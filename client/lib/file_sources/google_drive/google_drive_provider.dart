import 'dart:io' as io;

import 'package:meta/meta.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/file_sources/file_source_file.dart';
import 'package:mydatatools/file_sources/file_source_provider.dart';
import 'package:mydatatools/file_sources/google_drive/google_drive_auth_service.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/google_auth_client.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// [FileSourceProvider] implementation for Google Drive collections.
///
/// Uses the Drive v3 API via `package:googleapis`. Auth tokens are managed
/// by [GoogleDriveAuthService] which auto-refreshes near-expiry tokens
/// and persists the new values back to the [Collection] record in the DB.
///
/// **Scopes required:** `https://www.googleapis.com/auth/drive`
///
/// For scanning (background enumerating of all files/folders), see
/// [CloudFileIsolate] — that scanner re-instantiates this provider *inside*
/// the isolate via [GoogleDriveProvider.fromTokens].
class GoogleDriveProvider implements FileSourceProvider {
  static final AppLogger _logger = AppLogger(null);

  /// MIME type Google Drive uses to represent folders in its API.
  static const String _folderMimeType = 'application/vnd.google-apps.folder';

  /// Fields to request from the Drive API when listing files.
  /// Keeping this minimal reduces payload size and latency.
  static const String _fileFields =
      'id, name, mimeType, size, createdTime, modifiedTime, parents, '
      'webViewLink, thumbnailLink, trashed';

  const GoogleDriveProvider();

  @override
  String get providerKey => 'gdrive';

  @override
  String get scannerType => AppConstants.scannerFileGDrive;

  @override
  String get displayName => 'Google Drive';

  // ---------------------------------------------------------------------------
  // Browse
  // ---------------------------------------------------------------------------

  @override
  Future<List<FileSourceFile>> listFolder(
    Collection collection, {
    String? folderId,
  }) async {
    final api = await _buildApi(collection);
    final parentId =
        folderId ?? collection.path; // fall back to collection root

    final List<FileSourceFile> results = [];
    String? pageToken;

    do {
      final response = await api.files.list(
        q: "'$parentId' in parents and trashed = false",
        // Request specific fields to avoid fetching the entire resource
        $fields: 'nextPageToken, files($_fileFields)',
        pageToken: pageToken,
        pageSize: 200,
        orderBy: 'folder, name',
      );

      for (final f in response.files ?? []) {
        results.add(toFileSourceFile(f, parentId: parentId));
      }

      pageToken = response.nextPageToken;
    } while (pageToken != null);

    return results;
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Downloads [file] from Google Drive to [destPath] on disk.
  ///
  /// Uses the Drive `get` media endpoint which streams the raw bytes.
  /// For Google-native formats (Docs, Sheets, Slides) this will throw
  /// an [UnsupportedError] — those must be exported instead.
  @override
  Future<io.File> downloadFile(
    Collection collection,
    FileSourceFile file,
    String destPath,
  ) async {
    if (isGoogleNativeFormat(file.mimeType)) {
      throw UnsupportedError(
        'Google-native file "${file.name}" (${file.mimeType}) cannot be '
        'downloaded directly. Use the web view link to open it instead.',
      );
    }

    _logger.i('Downloading Drive file "${file.name}" → $destPath');

    final api = await _buildApi(collection);

    // Drive v3 media download: pass DownloadOptions.fullMedia
    final media =
        await api.files.get(
              file.id,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;

    final destFile = io.File(destPath);
    await destFile.parent.create(recursive: true);

    final sink = destFile.openWrite();
    try {
      await media.stream.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
    }

    _logger.i('Download complete: $destPath');
    return destFile;
  }

  /// Moves [file] to the Google Drive trash (soft delete).
  ///
  /// The file can be restored from Drive's trash by the user. Permanent
  /// deletion requires an additional API call and is intentionally deferred
  /// to give users a safety net.
  @override
  Future<bool> deleteFile(Collection collection, FileSourceFile file) async {
    try {
      _logger.i('Trashing Drive file "${file.name}" ($file.id)');
      final api = await _buildApi(collection);

      // Update the `trashed` field to move to trash rather than permanently delete
      await api.files.update(drive.File()..trashed = true, file.id);

      _logger.i('File "${file.name}" moved to Drive trash');
      return true;
    } catch (e, stack) {
      _logger.e('Failed to trash Drive file "${file.name}": $e\n$stack');
      return false;
    }
  }

  /// Opens [file] using its Google Drive web URL in the default browser.
  ///
  /// For files with a [FileSourceFile.webViewLink] this opens the Drive viewer.
  /// If there is no web view link (rare), falls back to the Drive file URL.
  @override
  Future<void> openFile(Collection collection, FileSourceFile file) async {
    final url =
        file.webViewLink ?? 'https://drive.google.com/file/d/${file.id}/view';

    if (await canLaunchUrlString(url)) {
      await launchUrlString(url);
    } else {
      _logger.w('Could not launch Drive URL: $url');
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Builds an authenticated Drive v3 API client for [collection].
  ///
  /// Uses [GoogleDriveAuthService] to obtain a valid (auto-refreshed if needed)
  /// access token, then wraps it in a [GoogleAuthClient].
  Future<drive.DriveApi> _buildApi(Collection collection) async {
    final accessToken = await GoogleDriveAuthService.getValidAccessToken(
      collection,
    );

    final authHttpClient = GoogleAuthClient({
      'Authorization': 'Bearer $accessToken',
    });

    return drive.DriveApi(authHttpClient);
  }

  /// Maps a Drive v3 [drive.File] to a [FileSourceFile] DTO.
  @visibleForTesting
  FileSourceFile toFileSourceFile(drive.File f, {required String parentId}) {
    final isFolder = f.mimeType == _folderMimeType;
    return FileSourceFile(
      id: f.id!,
      name: f.name ?? 'Untitled',
      parentId: parentId,
      mimeType: f.mimeType ?? 'application/octet-stream',
      // Drive API returns size as String for most file types; null for folders
      size: f.size != null ? int.tryParse(f.size!) : null,
      createdAt: f.createdTime,
      modifiedAt: f.modifiedTime,
      isFolder: isFolder,
      webViewLink: f.webViewLink,
      thumbnailLink: f.thumbnailLink,
    );
  }

  /// Returns true for Google-native formats that cannot be downloaded as-is
  /// and must be exported (e.g. Google Docs → .docx, Sheets → .xlsx).
  @visibleForTesting
  bool isGoogleNativeFormat(String mimeType) {
    return mimeType.startsWith('application/vnd.google-apps.') &&
        mimeType != _folderMimeType;
  }
}
