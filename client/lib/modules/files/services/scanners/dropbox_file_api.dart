import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart' as mime;
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart'
    show TokenRefreshResult;
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/refreshing_bearer_client.dart';

/// Dropbox rejected a request in a way no caller-side retry fixes.
class DropboxApiException implements Exception {
  final int status;
  final String message;

  const DropboxApiException(this.status, this.message);

  @override
  String toString() => 'DropboxApiException($status): $message';
}

/// Resolves the Dropbox ids stored for a path. Dropbox's `deleted` change
/// entries carry only a path, never an id, so removals are looked up here.
typedef DropboxIdsForPath = Future<List<String>> Function(String webLink);

/// Dropbox v2 HTTP API implementation of [CloudFileApi].
///
/// Identity: an item's id is Dropbox's `id:...` string, which is also a valid
/// `path` argument everywhere, so ids are used directly to list and download.
/// The collection root is the alias `root` (Dropbox's empty path).
class DropboxFileApi implements CloudFileApi, WholeDriveListing {
  static const _api = 'https://api.dropboxapi.com/2';
  static const _content = 'https://content.dropboxapi.com/2';
  static const _webHome = 'https://www.dropbox.com/home';

  /// Prefix of [CloudFileEntry.contentHash] values. Dropbox's `content_hash`
  /// is a hash of per-4MB-block hashes, NOT the SHA-256 of the bytes that
  /// local scans and Drive store. The prefix means a Dropbox value can never
  /// equal a plain SHA-256 hex string, so it can't produce a false duplicate
  /// against another source, while two Dropbox files with the same value
  /// (genuinely identical content) still dedupe.
  static const hashPrefix = 'dropbox:';

  final http.Client _client;
  final DropboxIdsForPath? _idsForPath;
  final Future<void> Function(Duration) _sleep;
  final int _maxRateLimitRetries;

  /// folder path_lower -> id, filled from folder entries seen in this run, so
  /// a changed item's parent id is usually known without a lookup call.
  final Map<String, String> _folderIdByPath = {};

  /// Ids reported as live in the change feed this run; a removal for one of
  /// them is the old half of a move and must not win.
  final Set<String> _liveIds = {};

  DropboxFileApi(
    this._client, {
    DropboxIdsForPath? idsForPath,
    Future<void> Function(Duration)? sleep,
    int maxRateLimitRetries = 4,
  }) : _idsForPath = idsForPath,
       _sleep = sleep ?? Future.delayed,
       _maxRateLimitRetries = maxRateLimitRetries;

  /// [CloudFileApiFactory] for Dropbox: refreshes the access token when it is
  /// within 5 minutes of expiry, then builds a client that keeps refreshing it.
  static Future<CloudFileApi> create(CloudFileApiCredentials c) async {
    Future<TokenRefreshResult> refresh() => refreshTokens(
      refreshToken: c.refreshToken,
      clientId: LoginProviders.dropbox.clientId(c.db),
    );
    var token = c.accessToken;
    var expiry = c.expiry?.toUtc();
    if (RefreshingBearerClient.isNearExpiry(expiry, DateTime.now().toUtc())) {
      final result = await refresh();
      token = result.accessToken;
      expiry = result.expiration;
    }
    return DropboxFileApi(
      RefreshingBearerClient(token: token, expiry: expiry, refresh: refresh),
      idsForPath: c.db == null ? null : (link) => _idsForLink(c.db!, link),
    );
  }

  /// PKCE-only refresh: `client_id` and the refresh token, no secret.
  static Future<TokenRefreshResult> refreshTokens({
    required String refreshToken,
    required Future<String> clientId,
    http.Client? client,
    DateTime Function()? now,
  }) async {
    final id = await clientId;
    if (id.isEmpty) {
      throw const CloudAuthException(
        'Dropbox app key is not configured',
        needsReAuth: true,
      );
    }
    final http.Response response;
    try {
      response = await (client ?? http.Client()).post(
        Uri.parse(LoginProviders.dropbox.tokenEndpoint),
        headers: {'Accept': 'application/json'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': id,
        },
      );
    } catch (e) {
      throw CloudAuthException('$e');
    }
    Map<String, dynamic> body = {};
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    final token = body['access_token'] as String?;
    if (token == null) {
      // invalid_grant = the refresh token was revoked or the app unlinked.
      throw CloudAuthException(
        '${body['error_description'] ?? body['error'] ?? 'refresh failed (HTTP ${response.statusCode})'}',
        needsReAuth: body['error'] == 'invalid_grant',
      );
    }
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 14400;
    return TokenRefreshResult(
      accessToken: token,
      expiration: (now ?? () => DateTime.now().toUtc())().add(
        Duration(seconds: seconds),
      ),
    );
  }

  static Future<List<String>> _idsForLink(AppDatabase db, String link) async {
    final ids = <String>[];
    final files = await db.select(
      'SELECT path FROM files WHERE lower(download_url) = lower(?)',
      [link],
    );
    for (final r in files) {
      ids.add((r['path'] as String).replaceFirst('dropbox://', ''));
    }
    final folders = await db.select(
      'SELECT path FROM folders WHERE lower(download_url) = lower(?)',
      [link],
    );
    for (final r in folders) {
      ids.add(r['path'] as String);
    }
    return ids;
  }

  @override
  String get scheme => 'dropbox';

  static String _path(String id) => id == 'root' ? '' : id;

  @override
  Future<CloudFilePage> listChildren(
    String folderId, {
    String? pageToken,
  }) async {
    final r =
        pageToken != null
            ? await _rpc('files/list_folder/continue', {'cursor': pageToken})
            : await _rpc('files/list_folder', {
              'path': _path(folderId),
              'recursive': false,
              'include_deleted': false,
              'include_non_downloadable_files': true,
              'limit': 2000,
            });
    final entries = _entries(r);
    _rememberFolders(entries);
    return CloudFilePage([
      for (final e in entries) e.$1,
    ], nextPageToken: r['has_more'] == true ? r['cursor'] as String : null);
  }

  @override
  Stream<List<CloudFileEntry>> listAllEntries() async* {
    var r = await _rpc('files/list_folder', {
      'path': '',
      'recursive': true,
      'include_deleted': false,
      'limit': 2000,
    });
    while (true) {
      yield [for (final e in _entries(r)) e.$1];
      if (r['has_more'] != true) return;
      r = await _rpc('files/list_folder/continue', {'cursor': r['cursor']});
    }
  }

  @override
  Future<String> startCursor() async {
    final r = await _rpc('files/list_folder/get_latest_cursor', {
      'path': '',
      'recursive': true,
      'include_deleted': true,
    });
    return r['cursor'] as String;
  }

  @override
  Future<CloudChangePage> listChanges(String cursor) async {
    final r = await _rpc('files/list_folder/continue', {'cursor': cursor});
    final raw =
        (r['entries'] as List? ?? const []).cast<Map<String, dynamic>>();
    final parsed = _entries(r);
    _rememberFolders(parsed);

    final changes = <CloudChange>[];
    for (final (entry, path) in parsed) {
      _liveIds.add(entry.id);
      final parent = await _parentId(path);
      changes.add(CloudChange(entry.id, entry: _withParent(entry, parent)));
    }
    for (final m in raw.where((m) => m['.tag'] == 'deleted')) {
      for (final id in await _idsForDeleted(m)) {
        if (!_liveIds.contains(id)) changes.add(CloudChange(id, removed: true));
      }
    }
    final more = r['has_more'] == true;
    return CloudChangePage(
      changes,
      nextPageCursor: more ? r['cursor'] as String : null,
      newStartCursor: more ? null : r['cursor'] as String,
    );
  }

  @override
  Future<CloudFileEntry?> getEntry(String id) async {
    if (id == 'root') return null;
    try {
      final m = await _rpc('files/get_metadata', {'path': id});
      return _toEntry(m)?.$1;
    } on DropboxApiException catch (e) {
      if (e.status == 409 && e.message.contains('not_found')) return null;
      rethrow;
    }
  }

  @override
  bool isDownloadableMimeType(String mimeType) => true;

  @override
  Future<void> download(String id, String destPath) async {
    final response = await _send(
      () =>
          http.Request('POST', Uri.parse('$_content/files/download'))
            ..headers['Dropbox-API-Arg'] = jsonEncode({'path': id}),
      stream: true,
    );
    final sink = io.File(destPath).openWrite();
    try {
      await (response as http.StreamedResponse).stream.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _rpc(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final response =
        await _send(
              () =>
                  http.Request('POST', Uri.parse('$_api/$endpoint'))
                    ..headers['Content-Type'] = 'application/json'
                    ..body = jsonEncode(body),
            )
            as http.Response;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Sends [build]'s request, retrying on 429 (honouring `Retry-After`) a
  /// bounded number of times. Maps 401 to [CloudAuthException] and a `reset`
  /// 409 to [CloudCursorExpiredException]. Returns a buffered [http.Response],
  /// or the live [http.StreamedResponse] when [stream] is set.
  Future<http.BaseResponse> _send(
    http.Request Function() build, {
    bool stream = false,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final streamed = await _client.send(build());
      if (streamed.statusCode == 200 && stream) return streamed;
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode == 200) return response;
      switch (response.statusCode) {
        case 429:
          if (attempt >= _maxRateLimitRetries) {
            throw const DropboxApiException(429, 'rate limited');
          }
          await _sleep(_retryAfter(response));
          continue;
        case 401:
          final expired = response.body.contains('expired_access_token');
          throw CloudAuthException(
            'Dropbox rejected the access token: ${response.body}',
            needsReAuth: !expired,
          );
        case 409:
          if (response.body.contains('"reset"') ||
              response.body.contains('reset/')) {
            throw const CloudCursorExpiredException('Dropbox cursor reset');
          }
      }
      throw DropboxApiException(response.statusCode, response.body);
    }
  }

  Duration _retryAfter(http.Response r) {
    var seconds = int.tryParse(r.headers['retry-after'] ?? '');
    if (seconds == null) {
      try {
        seconds =
            ((jsonDecode(r.body) as Map)['error']?['retry_after'] as num?)
                ?.toInt();
      } catch (_) {}
    }
    return Duration(seconds: (seconds ?? 1).clamp(1, 300));
  }

  /// Parsed non-deleted entries of a list response, each with its path_lower.
  List<(CloudFileEntry, String)> _entries(Map<String, dynamic> r) => [
    for (final m in (r['entries'] as List? ?? const []))
      if (_toEntry(m as Map<String, dynamic>) case final e?) e,
  ];

  void _rememberFolders(List<(CloudFileEntry, String)> entries) {
    for (final (e, path) in entries) {
      if (e.isFolder) _folderIdByPath[path] = e.id;
    }
  }

  /// Dropbox reports no parent id, only a path; resolve the parent folder's
  /// id so the scanner can place changed items. Null parent = collection root.
  Future<String?> _parentId(String pathLower) async {
    final slash = pathLower.lastIndexOf('/');
    if (slash <= 0) return 'root';
    final parentPath = pathLower.substring(0, slash);
    final cached = _folderIdByPath[parentPath];
    if (cached != null) return cached;
    try {
      final m = await _rpc('files/get_metadata', {'path': parentPath});
      final id = m['id'] as String?;
      if (id != null) _folderIdByPath[parentPath] = id;
      return id;
    } on DropboxApiException catch (e) {
      // Only a parent that is really gone is "no parent". Any other failure
      // must propagate: a null parent reads as out of scope to the scanner
      // and would remove live items.
      if (e.status == 409 && e.message.contains('not_found')) return null;
      rethrow;
    }
  }

  CloudFileEntry _withParent(CloudFileEntry e, String? parent) =>
      parent == null
          ? e
          : CloudFileEntry(
            id: e.id,
            name: e.name,
            isFolder: e.isFolder,
            parentIds: [parent],
            size: e.size,
            mimeType: e.mimeType,
            created: e.created,
            modified: e.modified,
            thumbnailLink: e.thumbnailLink,
            webLink: e.webLink,
            contentHash: e.contentHash,
            isDownloadable: e.isDownloadable,
          );

  Future<List<String>> _idsForDeleted(Map<String, dynamic> m) async {
    final display = m['path_display'] as String? ?? m['path_lower'] as String?;
    if (display == null || _idsForPath == null) return const [];
    return _idsForPath(_link(display));
  }

  static String _link(String pathDisplay) => '$_webHome$pathDisplay';

  /// Null for `deleted` entries (no id) and malformed ones.
  (CloudFileEntry, String)? _toEntry(Map<String, dynamic> m) {
    final tag = m['.tag'];
    final id = m['id'] as String?;
    final name = m['name'] as String?;
    if ((tag != 'file' && tag != 'folder') || id == null || name == null) {
      return null;
    }
    final path = (m['path_lower'] as String?) ?? '';
    final isFolder = tag == 'folder';
    final hash = m['content_hash'] as String?;
    return (
      CloudFileEntry(
        id: id,
        name: name,
        isFolder: isFolder,
        size: (m['size'] as num?)?.toInt(),
        mimeType: isFolder ? null : mime.lookupMimeType(name),
        created: DateTime.tryParse(m['client_modified'] as String? ?? ''),
        modified: DateTime.tryParse(m['server_modified'] as String? ?? ''),
        webLink: _link((m['path_display'] as String?) ?? path),
        contentHash: hash == null ? null : '$hashPrefix$hash',
        isDownloadable: !isFolder && m['is_downloadable'] != false,
      ),
      path,
    );
  }
}
