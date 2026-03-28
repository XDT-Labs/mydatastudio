import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/login_providers.dart';
import 'package:mydatatools/repositories/collection_repository.dart';

/// Manages Google OAuth token lifecycle for all Google collections
/// (Gmail and Drive).
///
/// Responsible for:
/// - Checking whether the stored access token is still valid.
/// - Refreshing the token using the stored refresh token (PKCE, no client_secret).
/// - Persisting the new token back to the [Collection] record in the DB.
///
/// Used by [GoogleDriveProvider] (UI actions), [CloudFileIsolateWorker]
/// (Drive background scanning), and [GmailScannerIsolateWorker] (email scanning).
/// The isolate version uses [refreshTokens] with raw token strings.
class GoogleAuthService {
  static final AppLogger _logger = AppLogger(null);

  /// Returns a valid access token for [collection], refreshing if needed.
  ///
  /// If the token is within [refreshThreshold] of expiry (default: 5 min),
  /// it will be refreshed and the new values persisted to the DB.
  ///
  /// Throws [GoogleAuthException] if the token cannot be refreshed
  /// (e.g. user revoked access). Callers should catch this and set
  /// [Collection.needsReAuth] = true, then surface a re-auth prompt.
  static Future<String> getValidAccessToken(
    Collection collection, {
    Duration refreshThreshold = const Duration(minutes: 5),
  }) async {
    if (collection.accessToken == null) {
      throw GoogleAuthException(
        'No access token stored for collection "${collection.name}".',
      );
    }

    final expiry = collection.expiration;
    final now = DateTime.now().toUtc();
    final needsRefresh =
        expiry == null || now.isAfter(expiry.subtract(refreshThreshold));

    if (!needsRefresh) {
      return collection.accessToken!;
    }

    _logger.i('Access token expired/near expiry — refreshing for "${collection.name}"');

    if (collection.refreshToken == null) {
      throw GoogleAuthException(
        'No refresh token stored for collection "${collection.name}". '
        'User must re-authenticate.',
      );
    }

    return _refreshAndPersist(collection);
  }

  /// Checks if a token needs refresh based on expiration timestamp.
  ///
  /// Use this in isolates where you have raw expiration data but no
  /// [Collection] object. Returns true if the token is expired or
  /// within [refreshThreshold] of expiry.
  static bool isTokenExpired(
    DateTime? expiration, {
    Duration refreshThreshold = const Duration(minutes: 5),
  }) {
    if (expiration == null) return true;
    final now = DateTime.now().toUtc();
    return now.isAfter(expiration.subtract(refreshThreshold));
  }

  /// Refreshes [accessToken] using [refreshToken] without touching the DB.
  ///
  /// Uses PKCE-compatible refresh: sends client_id and refresh_token only,
  /// no client_secret. This works because the original authorization grant
  /// used PKCE (S256 code challenge).
  ///
  /// Use this overload inside isolates where DB access or a [Collection] object
  /// is not available. The caller is responsible for persisting the new token
  /// if needed.
  static Future<TokenRefreshResult> refreshTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final provider = LoginProviders.google;
    final url = Uri.parse(provider.tokenEndpoint);

    // Google requires client_secret for desktop app token refresh,
    // even with PKCE enabled.
    final response = await http.post(
      url,
      headers: {'Accept': 'application/json'},
      body: {
        'refresh_token': refreshToken,
        'client_id': provider.clientId,
        'client_secret': provider.clientSecret,
        'grant_type': 'refresh_token',
      },
    );

    final body = jsonDecode(response.body) as Map<String, dynamic>;

    if (body['access_token'] == null) {
      throw GoogleAuthException(
        body['error_description']?.toString() ??
            body['error']?.toString() ??
            'Token refresh failed (status ${response.statusCode})',
      );
    }

    final expiresIn = body['expires_in'] as int? ?? 3600;
    final newExpiry = DateTime.now().toUtc().add(Duration(seconds: expiresIn));

    return TokenRefreshResult(
      accessToken: body['access_token'] as String,
      expiration: newExpiry,
    );
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Refreshes tokens and persists the updated [Collection] to the DB.
  static Future<String> _refreshAndPersist(Collection collection) async {
    try {
      final result = await refreshTokens(
        accessToken: collection.accessToken!,
        refreshToken: collection.refreshToken!,
      );

      // Persist updated token to the DB
      collection.accessToken = result.accessToken;
      collection.expiration = result.expiration;
      collection.needsReAuth = false;

      await CollectionRepository().updateCollection(collection);
      _logger.i(
        'Token refreshed successfully for "${collection.name}" — expires ${result.expiration}',
      );

      return result.accessToken;
    } on GoogleAuthException {
      // Mark collection as needing re-auth so the UI can prompt the user
      collection.needsReAuth = true;
      await CollectionRepository().updateCollection(collection);
      rethrow;
    }
  }
}

/// Holds the result of a successful token refresh.
class TokenRefreshResult {
  final String accessToken;
  final DateTime expiration;

  const TokenRefreshResult({
    required this.accessToken,
    required this.expiration,
  });
}

/// Thrown when a Google token cannot be obtained or refreshed.
class GoogleAuthException implements Exception {
  final String message;
  const GoogleAuthException(this.message);

  @override
  String toString() => 'GoogleAuthException: $message';
}

/// Simple authenticated HTTP client that injects a Bearer token header.
///
/// Use this to create API clients (DriveApi, GmailApi) from a valid
/// access token. This replaces the legacy GoogleAuthClient class.
class AuthenticatedHttpClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  AuthenticatedHttpClient(this._headers);

  /// Convenience constructor from a Bearer access token.
  AuthenticatedHttpClient.bearer(String accessToken)
      : _headers = {'Authorization': 'Bearer $accessToken'};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
