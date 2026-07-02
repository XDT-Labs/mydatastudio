import 'dart:io';

import 'package:mydatastudio/oauth/desktop_login_manager.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/oauth/json_accepting_http_client.dart';
import 'package:oauth2/oauth2.dart' as oauth2;

///
/// Based on this stackoverflow answer
/// https://stackoverflow.com/questions/68716993/google-microsoft-oauth2-login-flow-flutter-desktop-macos-windows-linux
class DesktopOAuthManager extends DesktopLoginManager {
  final LoginProviders loginProvider;

  DesktopOAuthManager({required this.loginProvider}) : super();

  Future<oauth2.Client> login({Map<String, String>? customParameters}) async {
    await redirectServer?.close();
    // Bind to an ephemeral port on localhost
    redirectServer = await HttpServer.bind('localhost', 0);
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
    // for all grants. Google requires client_secret alongside PKCE for desktop apps.
    final clientId = await loginProvider.clientId;
    final clientSecret = await loginProvider.clientSecret;

    if (clientId.isEmpty || clientSecret.isEmpty) {
      throw ProviderConfigurationException(
        'Please configure Client ID and Secret in Settings for ${loginProvider.key}.',
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
      httpClient: JsonAcceptingHttpClient(scopes: loginProvider.scopes),
      basicAuth: false,
      secret: clientSecret.isEmpty ? null : clientSecret,
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
