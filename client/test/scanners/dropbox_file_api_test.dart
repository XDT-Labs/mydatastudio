import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/modules/files/services/scanners/dropbox_file_api.dart';
import 'package:mydatastudio/scanners/cloud/cloud_file_api.dart';

Map<String, dynamic> _file(
  String id,
  String path, {
  String? hash,
  int size = 10,
}) => {
  '.tag': 'file',
  'id': id,
  'name': path.split('/').last,
  'path_lower': path.toLowerCase(),
  'path_display': path,
  'size': size,
  'client_modified': '2024-01-02T03:04:05Z',
  'server_modified': '2024-01-03T03:04:05Z',
  if (hash != null) 'content_hash': hash,
};

Map<String, dynamic> _folder(String id, String path) => {
  '.tag': 'folder',
  'id': id,
  'name': path.split('/').last,
  'path_lower': path.toLowerCase(),
  'path_display': path,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  late List<http.Request> requests;
  late List<Duration> sleeps;

  DropboxFileApi api(
    Future<http.Response> Function(http.Request r) handler, {
    DropboxIdsForPath? idsForPath,
    int maxRetries = 4,
  }) => DropboxFileApi(
    MockClient((r) async {
      requests.add(r);
      return handler(r);
    }),
    idsForPath: idsForPath,
    sleep: (d) async => sleeps.add(d),
    maxRateLimitRetries: maxRetries,
  );

  Map<String, dynamic> body(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  setUp(() {
    requests = [];
    sleeps = [];
  });

  group('listing', () {
    test('pages through list_folder and list_folder/continue', () async {
      final a = api((r) async {
        if (r.url.path.endsWith('/files/list_folder')) {
          return _json({
            'entries': [_folder('id:f1', '/Docs'), _file('id:a', '/a.txt')],
            'cursor': 'c1',
            'has_more': true,
          });
        }
        return _json({
          'entries': [_file('id:b', '/b.jpg', hash: 'abc')],
          'cursor': 'c2',
          'has_more': false,
        });
      });

      final first = await a.listChildren('root');
      expect(first.entries.map((e) => e.id), ['id:f1', 'id:a']);
      expect(first.entries.first.isFolder, isTrue);
      expect(first.nextPageToken, 'c1');
      expect(
        body(requests.first)['path'],
        '',
        reason: 'root is the empty path',
      );
      expect(body(requests.first)['recursive'], false);

      final second = await a.listChildren(
        'root',
        pageToken: first.nextPageToken,
      );
      expect(body(requests.last), {'cursor': 'c1'});
      expect(second.nextPageToken, isNull);
      expect(second.entries.single.mimeType, 'image/jpeg');
    });

    test('lists a sub-folder by its id', () async {
      final a = api(
        (r) async => _json({'entries': [], 'cursor': 'c', 'has_more': false}),
      );
      await a.listChildren('id:f1');
      expect(body(requests.single)['path'], 'id:f1');
    });

    test('maps metadata and links', () async {
      final a = api(
        (r) async => _json({
          'entries': [_file('id:a', '/Photos/Img.JPG', size: 42)],
          'cursor': 'c',
          'has_more': false,
        }),
      );
      final e = (await a.listChildren('root')).entries.single;
      expect(e.name, 'Img.JPG');
      expect(e.size, 42);
      expect(e.modified, DateTime.utc(2024, 1, 3, 3, 4, 5));
      expect(e.webLink, 'https://www.dropbox.com/home/Photos/Img.JPG');
      expect(e.isDownloadable, isTrue);
    });

    test('whole-drive listing is one recursive walk', () async {
      var n = 0;
      final a = api((r) async {
        n++;
        return _json({
          'entries': [_file('id:$n', '/f$n')],
          'cursor': 'c$n',
          'has_more': n < 2,
        });
      });
      final pages = await a.listAllEntries().toList();
      expect(pages.length, 2);
      expect(body(requests.first)['recursive'], true);
    });
  });

  group('content hash', () {
    test('is namespaced so it can never equal a SHA-256 hex digest', () async {
      final a = api(
        (r) async => _json({
          'entries': [_file('id:a', '/a', hash: 'a' * 64), _file('id:b', '/b')],
          'cursor': 'c',
          'has_more': false,
        }),
      );
      final entries = (await a.listChildren('root')).entries;
      // Dropbox hashes block hashes, not file bytes: a plain 64-hex value
      // would be compared against local sha256 values and could never match
      // honestly - but must also never be mistaken for one.
      expect(entries.first.contentHash, 'dropbox:${'a' * 64}');
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(entries.first.contentHash!),
        isFalse,
      );
      expect(entries.last.contentHash, isNull);
    });
  });

  group('changes', () {
    test('startCursor asks for a recursive latest cursor', () async {
      final a = api((r) async => _json({'cursor': 'latest'}));
      expect(await a.startCursor(), 'latest');
      expect(requests.single.url.path, endsWith('/get_latest_cursor'));
      expect(body(requests.single)['recursive'], true);
    });

    test('maps files and folders and resolves parent ids', () async {
      final a = api((r) async {
        if (r.url.path.endsWith('/get_metadata')) {
          expect(body(r)['path'], '/docs/sub');
          return _json(_folder('id:sub', '/Docs/Sub'));
        }
        return _json({
          'entries': [
            _folder('id:docs', '/Docs'),
            _file('id:in-docs', '/Docs/x.txt'),
            _file('id:in-sub', '/Docs/Sub/y.txt'),
            _file('id:top', '/top.txt'),
          ],
          'cursor': 'next',
          'has_more': false,
        });
      });
      final page = await a.listChanges('cur');
      final byId = {for (final c in page.changes) c.id: c};
      expect(byId['id:in-docs']!.entry!.parentIds, [
        'id:docs',
      ], reason: 'from batch');
      expect(byId['id:in-sub']!.entry!.parentIds, [
        'id:sub',
      ], reason: 'looked up');
      expect(byId['id:top']!.entry!.parentIds, ['root']);
      expect(page.newStartCursor, 'next');
      expect(page.nextPageCursor, isNull);
    });

    Future<http.Response> orphanFeed(http.Request r, int lookupStatus) async {
      if (r.url.path.endsWith('/get_metadata')) {
        return _json({'error_summary': 'path/not_found/..'}, lookupStatus);
      }
      return _json({
        'entries': [_file('id:x', '/Gone/x.txt')],
        'cursor': 'c',
        'has_more': false,
      });
    }

    test('a failing parent lookup fails the run instead of dropping items', () {
      final a = api((r) async => orphanFeed(r, 500));
      expect(a.listChanges('cur'), throwsA(isA<DropboxApiException>()));
    });

    test('a parent that is really gone is emitted without a parent', () async {
      final a = api((r) async => orphanFeed(r, 409));
      final page = await a.listChanges('cur');
      expect(page.changes.single.entry!.parentIds, isEmpty);
    });

    test('has_more becomes a next page cursor', () async {
      final a = api(
        (r) async => _json({'entries': [], 'cursor': 'mid', 'has_more': true}),
      );
      final page = await a.listChanges('cur');
      expect(page.nextPageCursor, 'mid');
      expect(page.newStartCursor, isNull);
    });

    test('deleted entries become removals by stored id', () async {
      final looked = <String>[];
      final a = api(
        (r) async => _json({
          'entries': [
            {
              '.tag': 'deleted',
              'name': 'Gone.txt',
              'path_lower': '/docs/gone.txt',
              'path_display': '/Docs/Gone.txt',
            },
          ],
          'cursor': 'c',
          'has_more': false,
        }),
        idsForPath: (link) async {
          looked.add(link);
          return ['id:gone'];
        },
      );
      final page = await a.listChanges('cur');
      expect(looked, ['https://www.dropbox.com/home/Docs/Gone.txt']);
      expect(page.changes.single.id, 'id:gone');
      expect(page.changes.single.removed, isTrue);
    });

    test('a move (delete at the old path + add) keeps the item', () async {
      final a = api(
        (r) async => _json({
          'entries': [
            {
              '.tag': 'deleted',
              'name': 'm.txt',
              'path_lower': '/old/m.txt',
              'path_display': '/Old/m.txt',
            },
            _file('id:m', '/new/m.txt'),
            _folder('id:new', '/new'),
          ],
          'cursor': 'c',
          'has_more': false,
        }),
        idsForPath: (_) async => ['id:m'],
      );
      final page = await a.listChanges('cur');
      final forM = page.changes.where((c) => c.id == 'id:m').toList();
      expect(forM.single.removed, isFalse);
      expect(forM.single.entry!.parentIds, ['id:new']);
    });

    test('a cursor reset is CloudCursorExpiredException', () async {
      final a = api(
        (r) async => _json({
          'error_summary': 'reset/..',
          'error': {'.tag': 'reset'},
        }, 409),
      );
      expect(
        a.listChanges('stale'),
        throwsA(isA<CloudCursorExpiredException>()),
      );
    });
  });

  group('errors', () {
    test('429 waits for Retry-After then retries', () async {
      var n = 0;
      final a = api((r) async {
        if (++n == 1) {
          return http.Response('{}', 429, headers: {'retry-after': '7'});
        }
        return _json({'entries': [], 'cursor': 'c', 'has_more': false});
      });
      await a.listChildren('root');
      expect(sleeps, [const Duration(seconds: 7)]);
      expect(requests.length, 2);
    });

    test('429 gives up after the bounded number of retries', () async {
      final a = api(
        (r) async => http.Response('{}', 429, headers: {'retry-after': '1'}),
        maxRetries: 2,
      );
      await expectLater(
        a.listChildren('root'),
        throwsA(isA<DropboxApiException>()),
      );
      expect(requests.length, 3);
      expect(sleeps.length, 2);
    });

    test('401 is a CloudAuthException', () async {
      final a = api(
        (r) async => _json({'error_summary': 'invalid_access_token/'}, 401),
      );
      expect(a.listChildren('root'), throwsA(isA<CloudAuthException>()));
    });

    test(
      'getEntry returns null for missing items and the root alias',
      () async {
        final a = api(
          (r) async => _json({'error_summary': 'path/not_found/..'}, 409),
        );
        expect(await a.getEntry('id:gone'), isNull);
        expect(await a.getEntry('root'), isNull);
      },
    );
  });

  group('download', () {
    test('streams the file with Dropbox-API-Arg to disk', () async {
      final dir = await io.Directory.systemTemp.createTemp('dbx');
      addTearDown(() => dir.delete(recursive: true));
      final a = api((r) async {
        expect(r.url.host, 'content.dropboxapi.com');
        expect(jsonDecode(r.headers['Dropbox-API-Arg']!), {'path': 'id:a'});
        return http.Response.bytes([1, 2, 3, 4], 200);
      });
      final dest = '${dir.path}/out.bin';
      await a.download('id:a', dest);
      expect(await io.File(dest).readAsBytes(), [1, 2, 3, 4]);
    });

    test('a file that is gone is CloudFileNotFoundException', () {
      final a = api(
        (r) async => _json({
          'error_summary': 'path/not_found/..',
          'error': {
            '.tag': 'path',
            'path': {'.tag': 'not_found'},
          },
        }, 409),
      );
      expect(
        a.download('id:a', '/tmp/never'),
        throwsA(isA<CloudFileNotFoundException>()),
      );
    });
  });

  group('thumbnails', () {
    test(
      'asks get_thumbnail_batch for small JPEGs and keys them by id',
      () async {
        final a = api((r) async {
          expect(
            r.url.toString(),
            'https://content.dropboxapi.com/2/files/get_thumbnail_batch',
          );
          final entries = body(r)['entries'] as List;
          expect(entries.map((e) => e['path']), ['id:a', 'id:b']);
          expect(entries.first['format'], 'jpeg');
          expect(entries.first['size'], 'w256h256');
          return _json({
            'entries': [
              {
                '.tag': 'success',
                'metadata': _file('id:a', '/a.jpg'),
                'thumbnail': base64Encode([9, 8, 7]),
              },
              {
                '.tag': 'failure',
                'failure': {'.tag': 'unsupported_image'},
              },
            ],
          });
        });
        final out = await a.thumbnails(['id:a', 'id:b']);
        // One failed entry must not cost the rest of the batch.
        expect(out.keys, ['id:a']);
        expect(out['id:a'], [9, 8, 7]);
      },
    );

    test('only image types Dropbox renders are asked for', () {
      final a = api((r) async => _json({}));
      expect(a.offersThumbnail('IMG_1.JPG', null), isTrue);
      expect(a.offersThumbnail('scan.png', null), isTrue);
      // HEIC and RAW fail per entry; asking would repeat on every sync.
      expect(a.offersThumbnail('IMG_2.HEIC', null), isFalse);
      expect(a.offersThumbnail('notes.txt', null), isFalse);
      expect(a.offersThumbnail('README', null), isFalse);
      expect(a.thumbnailBatchSize, 25);
    });
  });

  group('token refresh', () {
    test('sends client_id and refresh token, no secret', () async {
      late http.Request seen;
      final client = MockClient((r) async {
        seen = r;
        return _json({'access_token': 'new', 'expires_in': 14400});
      });
      final now = DateTime.utc(2026, 1, 1);
      final result = await DropboxFileApi.refreshTokens(
        refreshToken: 'rt',
        clientId: Future.value('app-key'),
        client: client,
        now: () => now,
      );
      expect(seen.url.toString(), 'https://api.dropboxapi.com/oauth2/token');
      expect(seen.bodyFields, {
        'grant_type': 'refresh_token',
        'refresh_token': 'rt',
        'client_id': 'app-key',
      });
      expect(result.accessToken, 'new');
      expect(result.expiration, now.add(const Duration(hours: 4)));
    });

    test('a revoked refresh token needs re-auth', () async {
      final client = MockClient(
        (r) async => _json({'error': 'invalid_grant'}, 400),
      );
      await expectLater(
        DropboxFileApi.refreshTokens(
          refreshToken: 'rt',
          clientId: Future.value('k'),
          client: client,
        ),
        throwsA(
          isA<CloudAuthException>().having(
            (e) => e.needsReAuth,
            'needsReAuth',
            isTrue,
          ),
        ),
      );
    });
  });
}
