import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/login_providers.dart';
import 'package:mydatatools/repositories/collection_repository.dart';

/// Manages Google OAuth token lifecycle for Drive collections.
///
/// Responsible for:
/// - Checking whether the stored access token is still valid.
/// - Refreshing the token using the stored refresh token.
/// - Persisting the new token back to the [Collection] record in the DB.
///
/// Used by [GoogleDriveProvider] (UI actions) and [CloudFileIsolateWorker]
/// (background scanning). The isolate version constructs this from raw token
/// strings — no BuildContext or DB reference required.
class GoogleDriveAuthService {
  static final AppLogger _logger = AppLogger(null);

  /// Returns a valid access token for [collection], refreshing if needed.
  ///
  /// If the token is within [refreshThreshold] of expiry (default: 5 min),
  /// it will be refreshed and the new values persisted to the DB.
  ///
  /// Throws [GoogleDriveAuthException] if the token cannot be refreshed
  /// (e.g. user revoked access). Callers should catch this and set
  /// [Collection.needsReAuth] = true, then surface a re-auth prompt.
  static Future<String> getValidAccessToken(
    Collection collection, {
    Duration refreshThreshold = const Duration(minutes: 5),
  }) async {
    if (collection.accessToken == null) {
      throw GoogleDriveAuthException(
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
      throw GoogleDriveAuthException(
        'No refresh token stored for collection "${collection.name}". '
        'User must re-authenticate.',
      );
    }

    return _refreshAndPersist(collection);
  }

  /// Refreshes [accessToken] using [refreshToken] without touching the DB.
  ///
  /// Use this overload inside isolates where DB access or a [Collection] object
  /// is not available. The caller is responsible for persisting the new token
  /// if needed.
  static Future<TokenRefreshResult> refreshTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    final provider = LoginProviders.googleDrive;
    final url = Uri.parse(provider.tokenEndpoint);

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
      throw GoogleDriveAuthException(
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
    } on GoogleDriveAuthException {
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

/// Thrown when a Google Drive token cannot be obtained or refreshed.
class GoogleDriveAuthException implements Exception {
  final String message;
  const GoogleDriveAuthException(this.message);

  @override
  String toString() => 'GoogleDriveAuthException: $message';
}
