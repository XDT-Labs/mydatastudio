import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/oauth/desktop_oauth_manager.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

class _FakeBrowser extends DesktopOAuthManager {
  Uri? authorizationUrl;

  _FakeBrowser(http.Client tokenServer)
    : super(
        loginProvider: LoginProviders.oneDrive,
        clientIdLoader: () async => 'entra-app-id',
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

/// OneDrive sign-in is a public client: the binary ships no secret, so a token
/// request that carried one (Entra rejects secrets from public clients) or
/// lacked the PKCE verifier would break every sign-in.
void main() {
  test(
    'uses the common authority, the shared Entra app and read-only scopes',
    () {
      expect(
        LoginProviders.oneDrive.authorizationEndpoint,
        'https://login.microsoftonline.com/common/oauth2/v2.0/authorize',
      );
      expect(
        LoginProviders.oneDrive.tokenEndpoint,
        'https://login.microsoftonline.com/common/oauth2/v2.0/token',
      );
      expect(LoginProviders.oneDrive.scopes, [
        'Files.Read',
        'offline_access',
        'User.Read',
        'openid',
        'email',
        'profile',
      ]);
      // Same providers row (client id) as Outlook mail.
      expect(LoginProviders.oneDrive.key, LoginProviders.outlook.key);
      expect(LoginProviders.oneDrive.usesPkce, isTrue);
      expect(LoginProviders.oneDrive.requiresClientSecret, isFalse);
    },
  );

  test('sign-in sends PKCE and scope and never a secret', () async {
    final requests = <http.Request>[];
    final server = MockClient((r) async {
      requests.add(r);
      return http.Response(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'token_type': 'Bearer',
          'expires_in': 3600,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final m = _FakeBrowser(server);
    final client = await m.login();
    await m.redirectServer?.close();

    final auth = m.authorizationUrl!;
    expect(auth.host, 'login.microsoftonline.com');
    expect(auth.queryParameters['code_challenge_method'], 'S256');
    expect(auth.queryParameters['scope'], contains('Files.Read'));

    final token = requests.single;
    expect(token.bodyFields['client_id'], 'entra-app-id');
    expect(token.bodyFields['code_verifier'], isNotEmpty);
    expect(token.bodyFields['scope'], contains('offline_access'));
    expect(token.bodyFields.containsKey('client_secret'), isFalse);
    expect(client.credentials.refreshToken, 'rt');
  });

  group('blocked consent', () {
    String? message(String error, String? description) =>
        LoginProviderExtension.oneDriveConsentBlockedMessage(
          oauth2.AuthorizationException(error, description, null),
        );

    test('admin-approval errors get a plain-language message', () {
      for (final (e, d) in [
        ('consent_required', null),
        (
          'access_denied',
          'AADSTS65001: The user or administrator has not consented',
        ),
        ('access_denied', 'AADSTS90094: Need admin approval'),
      ]) {
        expect(message(e, d), contains('administrator'), reason: '$e $d');
      }
    });

    test('other failures are left to the generic handling', () {
      expect(message('access_denied', 'user cancelled'), isNull);
      expect(
        LoginProviderExtension.oneDriveConsentBlockedMessage(StateError('x')),
        isNull,
      );
    });
  });
}
