import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/modules/files/services/scanners/google_drive_file_api.dart';

/// A full Drive scan can outlast one access token (about an hour). The client
/// must swap in a fresh token mid-scan, or every later request fails auth and
/// the walk, the deleted-file sweep and the downloads are lost.
void main() {
  final t0 = DateTime.utc(2026, 11, 2, 12);
  late DateTime now;
  late List<String> sentAuth;
  late int refreshes;

  RefreshingBearerClient client({DateTime? expiry}) => RefreshingBearerClient(
    token: 'old',
    expiry: expiry,
    now: () => now,
    inner: MockClient((req) async {
      sentAuth.add(req.headers['Authorization']!);
      return http.Response('{}', 200);
    }),
    refresh: () async {
      refreshes++;
      return TokenRefreshResult(
        accessToken: 'new$refreshes',
        expiration: now.add(const Duration(hours: 1)),
      );
    },
  );

  setUp(() {
    now = t0;
    sentAuth = [];
    refreshes = 0;
  });

  test('uses the current token while it is fresh', () async {
    final c = client(expiry: t0.add(const Duration(hours: 1)));
    await c.get(Uri.parse('https://x/a'));
    expect(sentAuth, ['Bearer old']);
    expect(refreshes, 0);
  });

  test('refreshes once the token nears expiry during a long scan', () async {
    final c = client(expiry: t0.add(const Duration(hours: 1)));
    await c.get(Uri.parse('https://x/a'));
    now = t0.add(const Duration(minutes: 56));
    await c.get(Uri.parse('https://x/b'));
    await c.get(Uri.parse('https://x/c'));
    expect(sentAuth, ['Bearer old', 'Bearer new1', 'Bearer new1']);
    expect(refreshes, 1);
  });

  test('concurrent requests share one refresh', () async {
    final c = client(expiry: t0);
    await Future.wait([
      for (var i = 0; i < 5; i++) c.get(Uri.parse('https://x/$i')),
    ]);
    expect(refreshes, 1);
    expect(sentAuth.toSet(), {'Bearer new1'});
  });
}
