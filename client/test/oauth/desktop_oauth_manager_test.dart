import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mydatastudio/oauth/desktop_oauth_manager.dart';
import 'package:mydatastudio/oauth/login_providers.dart';

/// Skips the browser and local redirect: captures the authorization URL and
/// answers with an authorization code.
class _FakeBrowserOAuthManager extends DesktopOAuthManager {
  Uri? authorizationUrl;

  _FakeBrowserOAuthManager({
    required super.requiresClientSecret,
    required super.clientIdLoader,
    required super.clientSecretLoader,
    required super.httpClient,
    super.loginProvider = LoginProviders.googleDrive,
  });

  @override
  Future<void> redirect(Uri url) async => authorizationUrl = url;

  @override
  Future<Map<String, String>> listen() async => {
    'code': 'auth-code',
    // The grant only sets `state` when asked to, so echo it only if present.
    if (authorizationUrl!.queryParameters['state'] case final state?)
      'state': state,
  };
}

void main() {
  late List<http.Request> tokenRequests;
  late MockClient tokenServer;

  setUp(() {
    tokenRequests = [];
    tokenServer = MockClient((request) async {
      tokenRequests.add(request);
      return http.Response(
        jsonEncode({
          'access_token': 'at',
          'refresh_token': 'rt',
          'token_type': 'bearer',
          'expires_in': 3600,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
  });

  _FakeBrowserOAuthManager manager({
    required bool requiresSecret,
    String secret = '',
  }) => _FakeBrowserOAuthManager(
    requiresClientSecret: requiresSecret,
    clientIdLoader: () async => 'client-123',
    clientSecretLoader: () async => secret,
    httpClient: tokenServer,
  );

  tearDown(() => tokenServer.close());

  test('provider that requires a secret still fails when it is missing', () {
    final m = manager(requiresSecret: true);
    expect(m.login(), throwsA(isA<ProviderConfigurationException>()));
  });

  test('Google keeps requiring a secret; Microsoft is a public client', () {
    expect(LoginProviders.google.requiresClientSecret, isTrue);
    expect(LoginProviders.googleDrive.requiresClientSecret, isTrue);
    expect(LoginProviders.outlook.requiresClientSecret, isFalse);
    expect(LoginProviders.azure.requiresClientSecret, isFalse);
  });

  group('Outlook as a public client', () {
    // requiresClientSecret is deliberately NOT passed: the provider's own
    // answer is what must let a secret-less sign-in start.
    _FakeBrowserOAuthManager outlook({
      String clientId = 'outlook-client',
      String secret = '',
    }) => _FakeBrowserOAuthManager(
      loginProvider: LoginProviders.outlook,
      requiresClientSecret: null,
      clientIdLoader: () async => clientId,
      clientSecretLoader: () async => secret,
      httpClient: tokenServer,
    );

    test('starts without any secret, with S256 PKCE on /common', () async {
      final m = outlook();
      await m.login();
      await m.redirectServer?.close();

      final url = m.authorizationUrl!;
      expect(url.host, 'login.microsoftonline.com');
      expect(url.path, '/common/oauth2/v2.0/authorize');
      expect(url.queryParameters['code_challenge_method'], 'S256');
      expect(url.queryParameters['code_challenge'], isNotEmpty);
      expect(
        url.queryParameters['redirect_uri'],
        matches(RegExp(r'^http://localhost:\d+$')),
      );
      expect(
        url.queryParameters['scope']!.split(' '),
        containsAll([
          'https://outlook.office.com/IMAP.AccessAsUser.All',
          'offline_access',
          'openid',
          'email',
        ]),
      );
    });

    test(
      'never sends a leftover stored secret, on exchange or refresh',
      () async {
        final m = outlook(secret: 'stale-secret-from-old-setup');
        final client = await m.login();
        await m.redirectServer?.close();
        await client.refreshCredentials();

        expect(tokenRequests, hasLength(2));
        for (final r in tokenRequests) {
          expect(r.bodyFields.containsKey('client_secret'), isFalse);
          expect(r.bodyFields['client_id'], 'outlook-client');
        }
        expect(tokenRequests.first.bodyFields['code_verifier'], isNotEmpty);
      },
    );

    test('still refuses to start with no client ID at all', () {
      final m = outlook(clientId: '');
      expect(m.login(), throwsA(isA<ProviderConfigurationException>()));
    });
  });

  test('public (PKCE-only) client builds an S256 authorization URL', () async {
    final m = manager(requiresSecret: false);
    await m.login();
    await m.redirectServer?.close();

    final q = m.authorizationUrl!.queryParameters;
    expect(q['client_id'], 'client-123');
    expect(q['code_challenge'], isNotEmpty);
    expect(q['code_challenge_method'], 'S256');
  });

  test('public client token exchange sends client_id and code_verifier, '
      'never client_secret', () async {
    final m = manager(requiresSecret: false);
    final client = await m.login();
    await m.redirectServer?.close();

    expect(tokenRequests, hasLength(1));
    final body = tokenRequests.single.bodyFields;
    expect(body['client_id'], 'client-123');
    expect(body['code_verifier'], isNotEmpty);
    expect(body.containsKey('client_secret'), isFalse);
    expect(tokenRequests.single.headers.containsKey('Authorization'), isFalse);
    expect(client.credentials.accessToken, 'at');
  });

  test(
    'refresh without a secret sends client_id and no client_secret',
    () async {
      final m = manager(requiresSecret: false);
      final client = await m.login();
      await m.redirectServer?.close();
      tokenRequests.clear();

      await client.refreshCredentials();

      final body = tokenRequests.single.bodyFields;
      expect(body['grant_type'], 'refresh_token');
      expect(body['client_id'], 'client-123');
      expect(body.containsKey('client_secret'), isFalse);
    },
  );

  test('provider with a secret still sends it', () async {
    final m = manager(requiresSecret: true, secret: 's3cret');
    await m.login();
    await m.redirectServer?.close();
    expect(tokenRequests.single.bodyFields['client_secret'], 's3cret');
  });
}
