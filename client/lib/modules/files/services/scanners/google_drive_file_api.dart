import 'dart:io' as io;

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/refreshing_bearer_client.dart';

/// Google Drive v3 implementation of [CloudFileApi].
class GoogleDriveFileApi implements CloudFileApi, WholeDriveListing {
  static const folderMimeType = 'application/vnd.google-apps.folder';

  static const _fields =
      'nextPageToken, files(id, name, mimeType, size, createdTime, '
      'modifiedTime, parents, thumbnailLink, webContentLink, sha256Checksum)';

  final drive.DriveApi _drive;

  GoogleDriveFileApi(this._drive);

  /// [CloudFileApiFactory] for Drive: refreshes the access token when it is
  /// within 5 minutes of expiry, then builds a client that keeps refreshing
  /// it, so a scan longer than one token's life keeps working.
  static Future<CloudFileApi> create(CloudFileApiCredentials c) async {
    Future<TokenRefreshResult> refresh() => _refresh(c);
    var token = c.accessToken;
    var expiry = c.expiry?.toUtc();
    if (RefreshingBearerClient.isNearExpiry(expiry, DateTime.now().toUtc())) {
      final result = await refresh();
      token = result.accessToken;
      expiry = result.expiration;
    }
    return GoogleDriveFileApi(
      drive.DriveApi(
        RefreshingBearerClient(token: token, expiry: expiry, refresh: refresh),
      ),
    );
  }

  static Future<TokenRefreshResult> _refresh(CloudFileApiCredentials c) async {
    try {
      return await GoogleAuthService.refreshTokens(
        accessToken: c.accessToken,
        refreshToken: c.refreshToken,
        db: c.db,
      );
    } on GoogleAuthException catch (e) {
      // Dead refresh token (revoked / OAuth client rotated).
      throw CloudAuthException('$e', needsReAuth: true);
    } catch (e) {
      throw CloudAuthException('$e');
    }
  }

  @override
  String get scheme => 'gdrive';

  @override
  Future<CloudFilePage> listChildren(String folderId, {String? pageToken}) =>
      _list(
        "'$folderId' in parents and trashed = false",
        pageToken,
        pageSize: 200,
        orderBy: 'folder, name',
      );

  /// Whole-drive listing for the pre-sync estimate: 1000 per page, minimal
  /// fields. Restricted to items we own, which is what a walk from 'root'
  /// reaches (shared-with-me items are not under My Drive).
  @override
  Stream<List<CloudFileEntry>> listAllEntries() async* {
    String? token;
    do {
      final r = await _drive.files.list(
        q: "trashed = false and 'me' in owners",
        $fields: 'nextPageToken, files(id, name, mimeType, size)',
        pageSize: 1000,
        pageToken: token,
      );
      yield [
        for (final f in r.files ?? const <drive.File>[])
          if (_toEntry(f) case final e?) e,
      ];
      token = r.nextPageToken;
    } while (token != null);
  }

  static const _changeFields =
      'nextPageToken, newStartPageToken, changes(fileId, removed, '
      'file(id, name, mimeType, size, createdTime, modifiedTime, parents, '
      'thumbnailLink, webContentLink, sha256Checksum, trashed))';

  @override
  Future<String> startCursor() async {
    final t = await _drive.changes.getStartPageToken();
    final token = t.startPageToken;
    if (token == null) throw StateError('Drive returned no start page token');
    return token;
  }

  @override
  Future<CloudChangePage> listChanges(String cursor) async {
    final drive.ChangeList r;
    try {
      r = await _drive.changes.list(
        cursor,
        includeRemoved: true,
        pageSize: 100,
        $fields: _changeFields,
      );
    } on drive.DetailedApiRequestError catch (e) {
      // A page token Drive no longer recognises comes back as 400/404/410.
      if (e.status == 400 || e.status == 404 || e.status == 410) {
        throw CloudCursorExpiredException('HTTP ${e.status}: ${e.message}');
      }
      rethrow;
    }
    return CloudChangePage(
      [
        for (final c in r.changes ?? const <drive.Change>[])
          if (c.fileId != null)
            if (c.removed == true || c.file?.trashed == true || c.file == null)
              CloudChange(c.fileId!, removed: true)
            else if (_toEntry(c.file!) case final e?)
              CloudChange(c.fileId!, entry: e),
      ],
      nextPageCursor: r.nextPageToken,
      newStartCursor: r.newStartPageToken,
    );
  }

  Future<CloudFilePage> _list(
    String q,
    String? pageToken, {
    required int pageSize,
    String? orderBy,
  }) async {
    final response = await _drive.files.list(
      q: q,
      $fields: _fields,
      pageToken: pageToken,
      pageSize: pageSize,
      orderBy: orderBy,
    );
    return CloudFilePage([
      for (final f in response.files ?? const <drive.File>[])
        if (_toEntry(f) case final e?) e,
    ], nextPageToken: response.nextPageToken);
  }

  @override
  Future<CloudFileEntry?> getEntry(String id) async {
    try {
      final f =
          await _drive.files.get(
                id,
                $fields:
                    'id, name, mimeType, size, createdTime, modifiedTime, '
                    'parents, thumbnailLink, webContentLink, sha256Checksum',
              )
              as drive.File;
      return _toEntry(f);
    } on drive.DetailedApiRequestError catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  bool isDownloadableMimeType(String mimeType) =>
      !(mimeType.startsWith('application/vnd.google-apps.') &&
          mimeType != folderMimeType);

  @override
  Future<void> download(String id, String destPath) async {
    final media =
        await _drive.files.get(
              id,
              downloadOptions: drive.DownloadOptions.fullMedia,
            )
            as drive.Media;
    final sink = io.File(destPath).openWrite();
    try {
      await media.stream.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  CloudFileEntry? _toEntry(drive.File f) {
    if (f.id == null || f.name == null) return null;
    final mime = f.mimeType;
    final isFolder = mime == folderMimeType;
    return CloudFileEntry(
      id: f.id!,
      name: f.name!,
      isFolder: isFolder,
      parentIds: f.parents ?? const [],
      size: f.size != null ? int.tryParse(f.size!) ?? 0 : null,
      mimeType: mime,
      created: f.createdTime,
      modified: f.modifiedTime,
      thumbnailLink: f.thumbnailLink,
      webLink: f.webContentLink,
      contentHash: f.sha256Checksum,
      isDownloadable: !isFolder && isDownloadableMimeType(mime ?? ''),
    );
  }
}
