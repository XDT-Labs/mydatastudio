import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/modules/files/services/scanners/onedrive_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';

const _graph = 'https://graph.microsoft.com/v1.0';

Map<String, dynamic> _file(
  String id,
  String name, {
  String parent = 'ROOT',
  String? qx,
  String? sha1,
  int size = 10,
}) => {
  'id': id,
  'name': name,
  'size': size,
  'webUrl': 'https://onedrive.live.com/?id=$id',
  'createdDateTime': '2024-01-01T00:00:00Z',
  'lastModifiedDateTime': '2024-01-03T03:04:05Z',
  'parentReference': {'id': parent},
  'file': {
    'mimeType': 'image/jpeg',
    'hashes': {
      if (qx != null) 'quickXorHash': qx,
      if (sha1 != null) 'sha1Hash': sha1,
    },
  },
};

Map<String, dynamic> _folder(
  String id,
  String name, {
  String parent = 'ROOT',
}) => {
  'id': id,
  'name': name,
  'parentReference': {'id': parent},
  'folder': {'childCount': 1},
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late List<http.Request> requests;
  late List<http.Request> plainRequests;
  late List<Duration> sleeps;

  OneDriveFileApi api(
    Future<http.Response> Function(http.Request r) handler, {
    Future<http.Response> Function(http.Request r)? plain,
    int maxRetries = 4,
  }) => OneDriveFileApi(
    MockClient((r) async {
      requests.add(r);
      return handler(r);
    }),
    redirectClient: MockClient((r) async {
      plainRequests.add(r);
      return plain!(r);
    }),
    sleep: (d) async => sleeps.add(d),
    maxRateLimitRetries: maxRetries,
  );

  setUp(() {
    requests = [];
    plainRequests = [];
    sleeps = [];
  });

  group('listing', () {
    test(
      'root alias lists /me/drive/root/children and follows nextLink',
      () async {
        final a = api((r) async {
          if (!r.url.queryParameters.containsKey('\$skiptoken')) {
            return _json({
              'value': [_folder('F1', 'Docs'), _file('A', 'a.jpg')],
              '@odata.nextLink': '$_graph/me/drive/root/children?\$skiptoken=x',
            });
          }
          return _json({
            'value': [_file('B', 'b.jpg')],
          });
        });
        final p1 = await a.listChildren('root');
        expect(p1.entries.map((e) => e.id), ['F1', 'A']);
        expect(p1.entries.first.isFolder, isTrue);
        expect(p1.nextPageToken, contains('skiptoken=x'));
        final p2 = await a.listChildren('root', pageToken: p1.nextPageToken);
        expect(p2.entries.single.id, 'B');
        expect(p2.nextPageToken, isNull);
      },
    );

    test('a folder id is listed through /items/{id}/children', () async {
      final a = api((r) async => _json({'value': []}));
      await a.listChildren('ABC!123');
      expect(requests.single.url.path, '/v1.0/me/drive/items/ABC!123/children');
    });

    test('maps metadata, parent and web link', () async {
      final a = api(
        (r) async => _json({
          'value': [_file('A', 'a.jpg', parent: 'P1', size: 42)],
        }),
      );
      final e = (await a.listChildren('root')).entries.single;
      expect(e.size, 42);
      expect(e.mimeType, 'image/jpeg');
      expect(e.parentIds, ['P1']);
      expect(e.webLink, 'https://onedrive.live.com/?id=A');
      expect(e.modified, DateTime.utc(2024, 1, 3, 3, 4, 5));
      expect(e.isDownloadable, isTrue);
    });

    test('OneNote packages and remote items are skipped', () async {
      final a = api(
        (r) async => _json({
          'value': [
            {
              'id': 'N',
              'name': 'Notebook',
              'package': {'type': 'oneNote'},
              'folder': {'childCount': 1},
            },
            {
              'id': 'R',
              'name': 'Shared',
              'remoteItem': {'id': 'x'},
              'folder': {'childCount': 1},
            },
            {'id': 'U', 'name': 'weird'},
            _file('A', 'a.jpg'),
          ],
        }),
      );
      expect((await a.listChildren('root')).entries.map((e) => e.id), ['A']);
    });

    test('whole-drive listing pages through a delta enumeration', () async {
      final a = api((r) async {
        if (!r.url.queryParameters.containsKey('\$skiptoken')) {
          return _json({
            'value': [
              {'id': 'ROOT', 'name': 'root', 'root': {}, 'folder': {}},
              _file('A', 'a.jpg'),
            ],
            '@odata.nextLink': '$_graph/me/drive/root/delta?\$skiptoken=s2',
          });
        }
        return _json({
          'value': [_file('B', 'b.jpg')],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=t',
        });
      });
      final pages = await a.listAllEntries().toList();
      expect(pages.expand((p) => p).map((e) => e.id), ['A', 'B']);
    });
  });

  group('content hash', () {
    test('is namespaced so it never equals a SHA-256 hex digest', () async {
      final a = api(
        (r) async => _json({
          'value': [
            _file('A', 'a', qx: 'AQIDBAUGBwgJCgsMDQ4PEBESExQ=', sha1: 'AB12'),
            _file('B', 'b', sha1: 'cd34'),
            _file('C', 'c'),
          ],
        }),
      );
      final e = (await a.listChildren('root')).entries;
      expect(e[0].contentHash, 'onedrive:qx:AQIDBAUGBwgJCgsMDQ4PEBESExQ=');
      expect(e[1].contentHash, 'onedrive:sha1:cd34');
      expect(e[2].contentHash, isNull);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(e[0].contentHash!), isFalse);
    });
  });

  group('changes', () {
    test('startCursor is the deltaLink of token=latest', () async {
      final a = api(
        (r) async => _json({
          'value': [],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=LATEST',
        }),
      );
      expect(await a.startCursor(), '$_graph/me/drive/root/delta?token=LATEST');
      expect(requests.single.url.queryParameters['token'], 'latest');
    });

    test('pages with nextLink, then hands back the new deltaLink', () async {
      final a = api((r) async {
        if (r.url.queryParameters['token'] == 'T1') {
          return _json({
            'value': [_file('A', 'a.jpg', parent: 'P1')],
            '@odata.nextLink': '$_graph/me/drive/root/delta?\$skiptoken=n',
          });
        }
        return _json({
          'value': [_folder('F', 'Docs', parent: 'ROOT')],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
        });
      });
      final p1 = await a.listChanges('$_graph/me/drive/root/delta?token=T1');
      expect(p1.changes.single.id, 'A');
      expect(p1.changes.single.entry!.parentIds, ['P1']);
      expect(p1.newStartCursor, isNull);
      final p2 = await a.listChanges(p1.nextPageCursor!);
      expect(p2.changes.single.entry!.isFolder, isTrue);
      expect(p2.nextPageCursor, isNull);
      expect(p2.newStartCursor, '$_graph/me/drive/root/delta?token=T2');
    });

    test('a deleted facet is a removal, even for a folder', () async {
      final a = api(
        (r) async => _json({
          'value': [
            {'id': 'A', 'deleted': {}},
            {
              'id': 'F',
              'name': 'x',
              'folder': {},
              'deleted': {'state': 'x'},
            },
          ],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
        }),
      );
      final page = await a.listChanges('$_graph/me/drive/root/delta?token=T1');
      expect(page.changes.map((c) => (c.id, c.removed, c.entry)), [
        ('A', true, null),
        ('F', true, null),
      ]);
    });

    test('the drive root item itself is not reported', () async {
      final a = api(
        (r) async => _json({
          'value': [
            {'id': 'ROOT', 'name': 'root', 'root': {}, 'folder': {}},
          ],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
        }),
      );
      expect(
        (await a.listChanges('$_graph/me/drive/root/delta?token=T1')).changes,
        isEmpty,
      );
    });

    test('410 Gone is CloudCursorExpiredException', () async {
      final a = api(
        (r) async => _json({
          'error': {'code': 'resyncRequired', 'message': 'resync'},
        }, 410),
      );
      expect(
        a.listChanges('$_graph/me/drive/root/delta?token=old'),
        throwsA(isA<CloudCursorExpiredException>()),
      );
    });

    test('a cursor that is not a Graph URL is never sent a token', () async {
      final a = api((r) async => _json({}));
      await expectLater(
        a.listChanges('https://evil.example/delta?token=x'),
        throwsA(isA<CloudCursorExpiredException>()),
      );
      expect(requests, isEmpty);
    });

    test(
      'a changed item without a parent gets it from the item lookup',
      () async {
        final a = api((r) async {
          if (r.url.path.endsWith('/items/A')) {
            return _json(_file('A', 'a.jpg', parent: 'P9'));
          }
          final noParent = _file('A', 'a.jpg')..remove('parentReference');
          return _json({
            'value': [noParent],
            '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
          });
        });
        final page = await a.listChanges(
          '$_graph/me/drive/root/delta?token=T1',
        );
        expect(page.changes.single.entry!.parentIds, ['P9']);
      },
    );

    test('a failing parent lookup fails the run instead of dropping items', () {
      final a = api((r) async {
        if (r.url.path.endsWith('/items/A')) return _json({}, 500);
        final noParent = _file('A', 'a.jpg')..remove('parentReference');
        return _json({
          'value': [noParent],
          '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
        });
      });
      expect(
        a.listChanges('$_graph/me/drive/root/delta?token=T1'),
        throwsA(isA<OneDriveApiException>()),
      );
    });

    test(
      'an item that vanished before its parent lookup is a removal',
      () async {
        final a = api((r) async {
          if (r.url.path.endsWith('/items/A')) {
            return _json({
              'error': {'code': 'itemNotFound'},
            }, 404);
          }
          final noParent = _file('A', 'a.jpg')..remove('parentReference');
          return _json({
            'value': [noParent],
            '@odata.deltaLink': '$_graph/me/drive/root/delta?token=T2',
          });
        });
        final page = await a.listChanges(
          '$_graph/me/drive/root/delta?token=T1',
        );
        expect(page.changes.single.removed, isTrue);
      },
    );
  });

  group('getEntry', () {
    test('404 is null', () async {
      final a = api((r) async => _json({'error': {}}, 404));
      expect(await a.getEntry('A'), isNull);
    });

    test('other failures throw rather than read as "gone"', () {
      final a = api((r) async => _json({'error': {}}, 500));
      expect(a.getEntry('A'), throwsA(isA<OneDriveApiException>()));
    });

    test('root resolves to the real root id', () async {
      final a = api(
        (r) async => _json({'id': 'REALROOT', 'name': 'root', 'folder': {}}),
      );
      expect((await a.getEntry('root'))!.id, 'REALROOT');
      expect(requests.single.url.path, '/v1.0/me/drive/root');
    });
  });

  group('errors', () {
    test('429 waits for Retry-After then retries', () async {
      var calls = 0;
      final a = api((r) async {
        if (++calls == 1) {
          return http.Response('', 429, headers: {'retry-after': '7'});
        }
        return _json({'value': []});
      });
      await a.listChildren('root');
      expect(sleeps, [const Duration(seconds: 7)]);
      expect(calls, 2);
    });

    test('503 is retried too, and the Retry-After wait is capped', () async {
      var calls = 0;
      final a = api((r) async {
        if (++calls == 1) {
          return http.Response('', 503, headers: {'retry-after': '99999'});
        }
        return _json({'value': []});
      });
      await a.listChildren('root');
      expect(sleeps.single, const Duration(seconds: 300));
    });

    test('throttling gives up after the bounded number of retries', () async {
      final a = api(
        (r) async => http.Response('', 429, headers: {'retry-after': '1'}),
        maxRetries: 2,
      );
      await expectLater(
        a.listChildren('root'),
        throwsA(isA<OneDriveApiException>()),
      );
      expect(requests.length, 3);
    });

    test('401 is a CloudAuthException', () {
      final a = api(
        (r) async => _json({
          'error': {'code': 'InvalidAuthenticationToken'},
        }, 401),
      );
      expect(a.listChildren('root'), throwsA(isA<CloudAuthException>()));
    });
  });

  group('download', () {
    test('follows the redirect without sending the bearer token on', () async {
      final dir = await io.Directory.systemTemp.createTemp('od');
      addTearDown(() => dir.delete(recursive: true));
      final a = api((r) async {
        expect(r.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://files.example.net/blob?sig=1'},
        );
      }, plain: (r) async => http.Response('hello', 200));
      final dest = '${dir.path}/out.bin';
      await a.download('A', dest);

      expect(requests.single.url.path, '/v1.0/me/drive/items/A/content');
      expect(plainRequests.single.url.host, 'files.example.net');
      expect(
        plainRequests.single.headers.containsKey('Authorization'),
        isFalse,
      );
      expect(await io.File(dest).readAsString(), 'hello');
    });

    test('a direct 200 is streamed to disk', () async {
      final dir = await io.Directory.systemTemp.createTemp('od');
      addTearDown(() => dir.delete(recursive: true));
      final a = api((r) async => http.Response('direct', 200));
      final dest = '${dir.path}/out.bin';
      await a.download('A', dest);
      expect(await io.File(dest).readAsString(), 'direct');
      expect(plainRequests, isEmpty);
    });

    test('a failed download throws', () {
      final a = api((r) async => _json({'error': {}}, 404));
      expect(
        a.download('A', '/tmp/never'),
        throwsA(isA<OneDriveApiException>()),
      );
    });
  });

  group('token refresh', () {
    test('sends client_id, refresh token and scope, no secret', () async {
      late http.Request seen;
      final result = await OneDriveFileApi.refreshTokens(
        refreshToken: 'rt',
        clientId: Future.value('cid'),
        client: MockClient((r) async {
          seen = r;
          return _json({'access_token': 'new', 'expires_in': 3600});
        }),
        now: () => DateTime.utc(2025),
      );
      expect(seen.url.toString(), contains('login.microsoftonline.com/common'));
      expect(seen.bodyFields['grant_type'], 'refresh_token');
      expect(seen.bodyFields['client_id'], 'cid');
      expect(seen.bodyFields['scope'], contains('Files.Read'));
      expect(seen.bodyFields.containsKey('client_secret'), isFalse);
      expect(result.accessToken, 'new');
      expect(result.expiration, DateTime.utc(2025, 1, 1, 1));
    });

    test('a revoked refresh token needs re-auth', () {
      expect(
        OneDriveFileApi.refreshTokens(
          refreshToken: 'rt',
          clientId: Future.value('cid'),
          client: MockClient(
            (r) async => _json({'error': 'invalid_grant'}, 400),
          ),
        ),
        throwsA(
          isA<CloudAuthException>().having(
            (e) => e.needsReAuth,
            'reAuth',
            true,
          ),
        ),
      );
    });
  });
}
