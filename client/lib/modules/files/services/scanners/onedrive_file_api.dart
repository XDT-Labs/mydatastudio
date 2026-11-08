import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:mime/mime.dart' as mime;
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart'
    show TokenRefreshResult;
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';
import 'package:mydatastudio/scanners/cloud/refreshing_bearer_client.dart';

/// Microsoft Graph rejected a request in a way no caller-side retry fixes.
class OneDriveApiException implements Exception {
  final int status;
  final String message;

  const OneDriveApiException(this.status, this.message);

  @override
  String toString() => 'OneDriveApiException($status): $message';
}

/// Microsoft Graph v1.0 implementation of [CloudFileApi] for the signed-in
/// user's own drive (`/me/drive`; personal and work/school accounts).
///
/// Identity: an item's id is Graph's driveItem id. Graph reports each item's
/// parent id directly (`parentReference.id`), so unlike Dropbox no path to id
/// resolution is needed. The collection root is the alias `root`; Graph
/// reports the root's real id as the parent of top-level items, which the
/// scanner resolves through [getEntry].
///
/// Change feed: the cursor is a complete `@odata.deltaLink` URL. Delta returns
/// the latest state of each item rather than every event, which is what the
/// scanner's "last change per id wins" handling expects.
class OneDriveFileApi
    implements CloudFileApi, WholeDriveListing, ServerThumbnails {
  static const _graph = 'https://graph.microsoft.com/v1.0';
  static const _graphHost = 'graph.microsoft.com';

  /// Prefix of [CloudFileEntry.contentHash] values. Graph's `quickXorHash`
  /// (a OneDrive-specific rolling XOR) and `sha1Hash` are NOT the SHA-256 of
  /// the bytes that local scans and Drive store. The prefix means a OneDrive
  /// value can never equal a plain SHA-256 hex string, so it can't produce a
  /// false duplicate against another source, while two OneDrive files with the
  /// same value (genuinely identical content) still dedupe. quickXor is
  /// preferred because both account types supply it; sha1 is the fallback.
  static const hashPrefix = 'onedrive:';

  final http.Client _client;

  /// Used only for the pre-authenticated download URL Graph redirects to. It
  /// must NOT add credentials: that host is not Graph and never needs them.
  final http.Client _redirectClient;
  final Future<void> Function(Duration) _sleep;
  final int _maxRateLimitRetries;

  OneDriveFileApi(
    this._client, {
    http.Client? redirectClient,
    Future<void> Function(Duration)? sleep,
    int maxRateLimitRetries = 4,
  }) : _redirectClient = redirectClient ?? http.Client(),
       _sleep = sleep ?? Future.delayed,
       _maxRateLimitRetries = maxRateLimitRetries;

  /// [CloudFileApiFactory] for OneDrive: refreshes the access token when it is
  /// within 5 minutes of expiry, then builds a client that keeps refreshing it.
  static Future<CloudFileApi> create(CloudFileApiCredentials c) async {
    Future<TokenRefreshResult> refresh() => refreshTokens(
      refreshToken: c.refreshToken,
      clientId: LoginProviders.oneDrive.clientId(c.db),
    );
    var token = c.accessToken;
    var expiry = c.expiry?.toUtc();
    if (RefreshingBearerClient.isNearExpiry(expiry, DateTime.now().toUtc())) {
      final result = await refresh();
      token = result.accessToken;
      expiry = result.expiration;
    }
    return OneDriveFileApi(
      RefreshingBearerClient(token: token, expiry: expiry, refresh: refresh),
    );
  }

  /// PKCE-only refresh: `client_id`, the refresh token and the scopes, no
  /// secret. Microsoft may rotate the refresh token; the one already stored
  /// keeps working for its sliding 90-day window, so only the access token is
  /// taken from the response.
  static Future<TokenRefreshResult> refreshTokens({
    required String refreshToken,
    required Future<String> clientId,
    http.Client? client,
    DateTime Function()? now,
  }) async {
    final id = await clientId;
    if (id.isEmpty) {
      throw const CloudAuthException(
        'Microsoft app (client) ID is not configured',
        needsReAuth: true,
      );
    }
    final http.Response response;
    try {
      response = await (client ?? http.Client()).post(
        Uri.parse(LoginProviders.oneDrive.tokenEndpoint),
        headers: {'Accept': 'application/json'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': id,
          'scope': LoginProviders.oneDrive.scopes.join(' '),
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
      final error = body['error'];
      throw CloudAuthException(
        '${body['error_description'] ?? error ?? 'refresh failed (HTTP ${response.statusCode})'}',
        needsReAuth:
            error == 'invalid_grant' || error == 'interaction_required',
      );
    }
    final seconds = (body['expires_in'] as num?)?.toInt() ?? 3600;
    return TokenRefreshResult(
      accessToken: token,
      expiration: (now ?? () => DateTime.now().toUtc())().add(
        Duration(seconds: seconds),
      ),
    );
  }

  @override
  String get scheme => 'onedrive';

  static String _itemUrl(String id) =>
      id == 'root'
          ? '$_graph/me/drive/root'
          : '$_graph/me/drive/items/${Uri.encodeComponent(id)}';

  @override
  Future<CloudFilePage> listChildren(
    String folderId, {
    String? pageToken,
  }) async {
    final r = await _getJson(
      pageToken ?? '${_itemUrl(folderId)}/children?\$top=200',
    );
    return CloudFilePage([
      for (final e in _entries(r)) e,
    ], nextPageToken: r['@odata.nextLink'] as String?);
  }

  /// Graph has no recursive listing; an initial `delta` enumeration (no token)
  /// is the supported way to read every item of a drive in large pages.
  @override
  Stream<List<CloudFileEntry>> listAllEntries() async* {
    String? next = '$_graph/me/drive/root/delta?\$top=200';
    while (next != null) {
      final r = await _getJson(next);
      yield [
        for (final m in _liveItems(r))
          if (_toEntry(m) case final e?) e,
      ];
      next = r['@odata.nextLink'] as String?;
    }
  }

  @override
  Future<String> startCursor() async {
    String? next = '$_graph/me/drive/root/delta?token=latest';
    while (next != null) {
      final r = await _getJson(next);
      final link = r['@odata.deltaLink'] as String?;
      if (link != null) return link;
      next = r['@odata.nextLink'] as String?;
    }
    throw const OneDriveApiException(200, 'delta returned no deltaLink');
  }

  @override
  Future<CloudChangePage> listChanges(String cursor) async {
    // The cursor is stored data that gets a bearer token attached; never send
    // that to anything but Graph. An unusable cursor means a full re-list.
    if (Uri.tryParse(cursor)?.host != _graphHost) {
      throw const CloudCursorExpiredException('delta link is not a Graph URL');
    }
    final Map<String, dynamic> r;
    try {
      r = await _getJson(cursor);
    } on OneDriveApiException catch (e) {
      if (e.status == 410 ||
          e.message.contains('resyncRequired') ||
          e.message.contains('syncStateNotFound')) {
        throw CloudCursorExpiredException('Graph delta: ${e.message}');
      }
      rethrow;
    }

    final changes = <CloudChange>[];
    for (final m in (r['value'] as List? ?? const [])) {
      final item = m as Map<String, dynamic>;
      final id = item['id'] as String?;
      if (id == null || item.containsKey('root')) continue;
      if (item.containsKey('deleted')) {
        changes.add(CloudChange(id, removed: true));
        continue;
      }
      var entry = _toEntry(item);
      if (entry == null) continue;
      if (entry.parentIds.isEmpty) {
        // A null parent reads as out of scope to the scanner and would remove
        // a live item, so resolve it, and let a failed lookup propagate.
        final fetched = await getEntry(id);
        if (fetched == null) {
          changes.add(CloudChange(id, removed: true));
          continue;
        }
        if (fetched.parentIds.isEmpty) {
          throw OneDriveApiException(200, 'no parent reported for $id');
        }
        entry = fetched;
      }
      changes.add(CloudChange(id, entry: entry));
    }
    final next = r['@odata.nextLink'] as String?;
    return CloudChangePage(
      changes,
      nextPageCursor: next,
      newStartCursor: next == null ? r['@odata.deltaLink'] as String? : null,
    );
  }

  @override
  Future<CloudFileEntry?> getEntry(String id) async {
    try {
      return _toEntry(await _getJson(_itemUrl(id)));
    } on OneDriveApiException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  @override
  bool isDownloadableMimeType(String mimeType) => true;

  @override
  Future<void> download(String id, String destPath) async {
    final response = await _getContent('${_itemUrl(id)}/content');
    final sink = io.File(destPath).openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// Graph renders thumbnails for images and videos (and some documents, which
  /// aren't asked for here).
  @override
  bool offersThumbnail(String name, String? mimeType) {
    final cat = ContentPolicy.categorize(mimeType, name);
    return cat == ContentCategory.images || cat == ContentCategory.videos;
  }

  /// Graph has no batch thumbnail call that returns bytes, so a "batch" is a
  /// few single requests in parallel.
  @override
  int get thumbnailBatchSize => 4;

  @override
  Future<Map<String, Uint8List>> thumbnails(List<String> ids) async {
    final out = <String, Uint8List>{};
    await Future.wait([
      for (final id in ids)
        () async {
          try {
            final response = await _getContent(
              '${_itemUrl(id)}/thumbnails/0/medium/content',
            );
            out[id] = await response.stream.toBytes();
          } on OneDriveApiException catch (e) {
            // No thumbnail for this item (404); anything else is a real error.
            if (e.status != 404) rethrow;
          }
        }(),
    ]);
    return out;
  }

  /// GETs a Graph `/content` URL. Graph answers 302 with a short-lived
  /// pre-authenticated URL; follow it by hand so the bearer token goes to
  /// Graph only, never to the storage host the redirect points at.
  Future<http.StreamedResponse> _getContent(String url) async {
    final response =
        await _send(
              () => http.Request('GET', Uri.parse(url))..followRedirects = false,
              stream: true,
              accept: _okOrRedirect,
            )
            as http.StreamedResponse;
    if (response.statusCode == 200) return response;
    final location = response.headers['location'];
    await response.stream.drain<void>();
    if (location == null) {
      throw OneDriveApiException(
        response.statusCode,
        'redirect without a Location',
      );
    }
    return await _send(
          () => http.Request('GET', Uri.parse(location)),
          stream: true,
          client: _redirectClient,
        )
        as http.StreamedResponse;
  }

  // ---------------------------------------------------------------------------

  static const _okOrRedirect = {200, 301, 302, 303, 307, 308};

  Future<Map<String, dynamic>> _getJson(String url) async {
    final uri = Uri.parse(url);
    if (uri.host != _graphHost) {
      throw OneDriveApiException(0, 'refusing to call non-Graph URL $uri');
    }
    final response =
        await _send(() => http.Request('GET', uri)) as http.Response;
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// Sends [build]'s request, retrying on 429/503 (honouring `Retry-After`) a
  /// bounded number of times. Maps 401 from Graph to [CloudAuthException].
  /// Returns a buffered [http.Response], or the live [http.StreamedResponse]
  /// when [stream] is set.
  Future<http.BaseResponse> _send(
    http.Request Function() build, {
    bool stream = false,
    http.Client? client,
    Set<int> accept = const {200},
  }) async {
    final c = client ?? _client;
    for (var attempt = 0; ; attempt++) {
      final streamed = await c.send(build());
      if (accept.contains(streamed.statusCode)) {
        return stream ? streamed : await http.Response.fromStream(streamed);
      }
      final response = await http.Response.fromStream(streamed);
      switch (response.statusCode) {
        case 429:
        case 503:
          if (attempt >= _maxRateLimitRetries) {
            throw OneDriveApiException(response.statusCode, 'throttled');
          }
          await _sleep(_retryAfter(response));
          continue;
        case 401 when identical(c, _client):
          final expired = response.body.contains('expired');
          throw CloudAuthException(
            'Microsoft rejected the access token: ${response.body}',
            needsReAuth: !expired,
          );
      }
      throw OneDriveApiException(response.statusCode, response.body);
    }
  }

  Duration _retryAfter(http.Response r) {
    final seconds = int.tryParse(r.headers['retry-after'] ?? '');
    return Duration(seconds: (seconds ?? 1).clamp(1, 300));
  }

  /// Non-deleted, non-root items of a list or delta response.
  Iterable<Map<String, dynamic>> _liveItems(Map<String, dynamic> r) sync* {
    for (final m in (r['value'] as List? ?? const [])) {
      final item = m as Map<String, dynamic>;
      if (item.containsKey('deleted') || item.containsKey('root')) continue;
      yield item;
    }
  }

  List<CloudFileEntry> _entries(Map<String, dynamic> r) => [
    for (final m in _liveItems(r))
      if (_toEntry(m) case final e?) e,
  ];

  /// Null for items this connector does not index: OneNote packages, remote
  /// (shared-in) items, whose ids don't belong to `/me/drive`, and anything
  /// that is neither a file nor a folder.
  CloudFileEntry? _toEntry(Map<String, dynamic> m) {
    final id = m['id'] as String?;
    final name = m['name'] as String?;
    if (id == null ||
        name == null ||
        m.containsKey('package') ||
        m.containsKey('remoteItem')) {
      return null;
    }
    final fileFacet = m['file'] as Map<String, dynamic>?;
    final isFolder = m.containsKey('folder');
    if (!isFolder && fileFacet == null) return null;

    final parent = (m['parentReference'] as Map?)?['id'] as String?;
    final info = m['fileSystemInfo'] as Map<String, dynamic>?;
    final hashes = fileFacet?['hashes'] as Map<String, dynamic>?;
    final qx = hashes?['quickXorHash'] as String?;
    final sha1 = hashes?['sha1Hash'] as String?;
    return CloudFileEntry(
      id: id,
      name: name,
      isFolder: isFolder,
      parentIds: parent == null ? const [] : [parent],
      size: (m['size'] as num?)?.toInt(),
      mimeType:
          isFolder
              ? null
              : (fileFacet!['mimeType'] as String?) ??
                  mime.lookupMimeType(name),
      created: DateTime.tryParse(
        (info?['createdDateTime'] ?? m['createdDateTime'] ?? '') as String,
      ),
      modified: DateTime.tryParse(
        (info?['lastModifiedDateTime'] ?? m['lastModifiedDateTime'] ?? '')
            as String,
      ),
      webLink: m['webUrl'] as String?,
      contentHash:
          qx != null
              ? '${hashPrefix}qx:$qx'
              : (sha1 != null ? '${hashPrefix}sha1:$sha1' : null),
      isDownloadable: !isFolder,
    );
  }
}
