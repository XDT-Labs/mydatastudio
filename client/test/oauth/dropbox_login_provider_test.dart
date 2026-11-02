import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/oauth/desktop_oauth_manager.dart';
import 'package:mydatastudio/oauth/login_providers.dart';

class _FakeBrowser extends DesktopOAuthManager {
  Uri? authorizationUrl;

  _FakeBrowser(http.Client tokenServer)
    : super(
        loginProvider: LoginProviders.dropbox,
        clientIdLoader: () async => 'app-key',
        clientSecretLoader: () async => '',
        httpClient: tokenServer,
      );

  @override
  Future<void> redirect(Uri url) async => authorizationUrl = url;

  @override
  Future<Map<String, String>> listen() async => {
    'code': 'auth-code',
    if (authorizationUrl!.queryParameters['state'] case final state?)
      'state': state,
  };
}

/// Dropbox desktop sign-in must be PKCE-only: the binary ships no secret, so
/// a request that carried one (or lacked the verifier) would be a regression
/// that either leaks a credential or fails every sign-in.
void main() {
  test('uses Dropbox endpoints and the read-only scopes', () {
    expect(
      LoginProviders.dropbox.authorizationEndpoint,
      'https://www.dropbox.com/oauth2/authorize',
    );
    expect(
      LoginProviders.dropbox.tokenEndpoint,
      'https://api.dropboxapi.com/oauth2/token',
    );
    expect(LoginProviders.dropbox.scopes, [
      'account_info.read',
      'files.metadata.read',
      'files.content.read',
    ]);
    expect(LoginProviders.dropbox.key, 'dropbox');
    expect(LoginProviders.dropbox.usesPkce, isTrue);
    expect(LoginProviders.dropbox.requiresClientSecret, isFalse);
  });

  test('sign-in sends PKCE + offline access and never a secret', () async {
    final requests = <http.Request>[];
    final server = MockClient((r) async {
      requests.add(r);
      return http.Response(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'token_type': 'bearer',
          'expires_in': 14400,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final m = _FakeBrowser(server);
    final client = await m.login(
      customParameters: {'token_access_type': 'offline'},
    );
    await m.redirectServer?.close();

    final auth = m.authorizationUrl!;
    expect(auth.host, 'www.dropbox.com');
    expect(auth.queryParameters['token_access_type'], 'offline');
    expect(auth.queryParameters['code_challenge_method'], 'S256');
    expect(auth.queryParameters['code_challenge'], isNotEmpty);
    expect(
      auth.queryParameters['scope'],
      'account_info.read files.metadata.read files.content.read',
    );

    final token = requests.single;
    expect(token.url.toString(), 'https://api.dropboxapi.com/oauth2/token');
    expect(token.bodyFields['client_id'], 'app-key');
    expect(token.bodyFields['code_verifier'], isNotEmpty);
    expect(token.bodyFields.containsKey('client_secret'), isFalse);
    expect(token.headers.containsKey('Authorization'), isFalse);
    expect(client.credentials.refreshToken, 'rt');
  });
}
