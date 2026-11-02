import 'dart:io';

import 'package:mydatastudio/oauth/desktop_login_manager.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/oauth/json_accepting_http_client.dart';
import 'package:http/http.dart' as http;
import 'package:oauth2/oauth2.dart' as oauth2;

///
/// Based on this stackoverflow answer
/// https://stackoverflow.com/questions/68716993/google-microsoft-oauth2-login-flow-flutter-desktop-macos-windows-linux
class DesktopOAuthManager extends DesktopLoginManager {
  final LoginProviders loginProvider;

  /// Overrides [LoginProviders.requiresClientSecret]; for tests.
  final bool? requiresClientSecret;
  final Future<String> Function()? clientIdLoader;
  final Future<String> Function()? clientSecretLoader;

  /// Underlying transport for token requests; defaults to a real client.
  final http.Client? httpClient;

  DesktopOAuthManager({
    required this.loginProvider,
    this.requiresClientSecret,
    this.clientIdLoader,
    this.clientSecretLoader,
    this.httpClient,
  }) : super();

  Future<oauth2.Client> login({Map<String, String>? customParameters}) async {
    await redirectServer?.close();
    // An ephemeral port, unless the provider must see the exact registered
    // redirect URI.
    redirectServer = await HttpServer.bind(
      'localhost',
      loginProvider.redirectPort ?? 0,
    );
    final redirectURL = 'http://localhost:${redirectServer!.port}/auth';
    var client = await _getOAuth2Client(
      Uri.parse(redirectURL),
      customParameters: customParameters,
    );
    return client;
  }

  Future<oauth2.Client> _getOAuth2Client(
    Uri redirectUrl, {
    Map<String, String>? customParameters,
  }) async {
    // The oauth2 package auto-generates PKCE (code_verifier + S256 code_challenge)
    // for all grants. Google requires client_secret alongside PKCE for desktop
    // apps; public clients (see [LoginProviders.requiresClientSecret]) rely on
    // PKCE alone and send no secret.
    final clientId = await (clientIdLoader ?? loginProvider.clientId)();
    final clientSecret =
        await (clientSecretLoader ?? loginProvider.clientSecret)();
    final needsSecret =
        requiresClientSecret ?? loginProvider.requiresClientSecret;

    if (clientId.isEmpty || (needsSecret && clientSecret.isEmpty)) {
      throw ProviderConfigurationException(
        needsSecret
            ? 'Please configure Client ID and Secret in Settings for ${loginProvider.key}.'
            : 'Please configure Client ID in Settings for ${loginProvider.key}.',
      );
    }

    var grant = oauth2.AuthorizationCodeGrant(
      clientId,
      Uri.parse(
        loginProvider.authorizationEndpoint.replaceAll(
          '{tenant}',
          loginProvider.tenant,
        ),
      ),
      Uri.parse(
        loginProvider.tokenEndpoint.replaceAll(
          '{tenant}',
          loginProvider.tenant,
        ),
      ),
      httpClient: JsonAcceptingHttpClient(
        httpClient: httpClient,
        scopes:
            loginProvider.tokenRequestNeedsScope ? loginProvider.scopes : null,
      ),
      basicAuth: false,
      secret: needsSecret && clientSecret.isNotEmpty ? clientSecret : null,
    );
    var authorizationUrl = grant.getAuthorizationUrl(
      redirectUrl,
      scopes: loginProvider.scopes,
    );

    if (customParameters != null && customParameters.isNotEmpty) {
      authorizationUrl = authorizationUrl.replace(
        queryParameters: {
          ...authorizationUrl.queryParameters,
          ...customParameters,
        },
      );
    }

    await redirect(authorizationUrl);
    var responseQueryParameters = await listen();
    var client = await grant.handleAuthorizationResponse(
      responseQueryParameters,
    );
    return client;
  }
}
