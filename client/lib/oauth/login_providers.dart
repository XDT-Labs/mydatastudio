import 'dart:convert';
import 'dart:io';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/provider.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/credential_codec.dart';
import 'package:mydatastudio/oauth/desktop_oauth_manager.dart';
import 'package:mydatastudio/scanners/scanner_manager.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';
import 'package:mydatastudio/database_manager.dart';

// ignore: constant_identifier_names
enum LoginProviders { google, googleDrive, azure, outlook }

class GoogleUserProfile {
  final String userId;
  final String email;

  const GoogleUserProfile({required this.userId, required this.email});
}

class ProviderConfigurationException implements Exception {
  final String message;
  ProviderConfigurationException(this.message);

  @override
  String toString() => 'ProviderConfigurationException: $message';
}

///
/// Based on this stackoverflow answer
/// https://stackoverflow.com/questions/68716993/google-microsoft-oauth2-login-flow-flutter-desktop-macos-windows-linux
extension LoginProviderExtension on LoginProviders {
  String get key {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return 'google';
      case LoginProviders.azure:
      case LoginProviders.outlook:
        return 'azure';
    }
  }

  String get tenant {
    switch (this) {
      case LoginProviders.outlook:
        return "consumers";
      default:
        return "common";
    }
  }

  String get authorizationEndpoint {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return "https://accounts.google.com/o/oauth2/v2/auth";
      case LoginProviders.azure:
      case LoginProviders.outlook:
        return "https://login.microsoftonline.com/$tenant/oauth2/v2.0/authorize";
    }
  }

  String get tokenEndpoint {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return "https://oauth2.googleapis.com/token";
      case LoginProviders.azure:
      case LoginProviders.outlook:
        return "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token";
    }
  }

  /// OAuth client ID.
  ///
  /// Defaults to [DatabaseManager]'s singleton connection — correct for
  /// main-isolate/UI callers, which is everything except the scanner/
  /// embedding worker isolates. Isolates never touch `DatabaseManager` (it's
  /// a singleton, and each spawned isolate gets its own separate copy of all
  /// static state — its `database` field is always null there), so they
  /// must pass their own local [db], or this silently resolves to an empty
  /// string exactly as if nothing were configured.
  Future<String> clientId([AppDatabase? db]) async {
    final database = db ?? DatabaseManager.instance.database;
    if (database != null) {
      final rows = await database.select(
        "SELECT * FROM providers WHERE service = ?",
        [key],
      );
      if (rows.isNotEmpty) {
        final provider = Provider.fromDbMap(rows.first);
        if (provider.clientId != null && provider.clientId!.isNotEmpty) {
          return provider.clientId!;
        }
      }
    }

    return '';
  }

  /// Whether this provider uses PKCE (code_challenge + code_verifier).
  /// Google desktop apps use PKCE per https://developers.google.com/identity/protocols/oauth2/native-app
  /// Note: Google still requires client_secret alongside PKCE for desktop clients.
  bool get usesPkce {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return true;
      case LoginProviders.azure:
      case LoginProviders.outlook:
        return false;
    }
  }

  /// OAuth client secret.
  /// Google requires client_secret for desktop apps even with PKCE enabled.
  ///
  /// See [clientId] for why isolate callers must pass their own local [db].
  Future<String> clientSecret([AppDatabase? db]) async {
    final database = db ?? DatabaseManager.instance.database;
    if (database != null) {
      final rows = await database.select(
        "SELECT * FROM providers WHERE service = ?",
        [key],
      );
      if (rows.isNotEmpty) {
        final provider = Provider.fromDbMap(rows.first);
        if (provider.clientSecret != null &&
            provider.clientSecret!.isNotEmpty) {
          // Stored encrypted (AUDIT M2 phase 3/4). Decrypt to plaintext for the
          // token endpoint. In worker isolates the DEK must be installed first;
          // a locked codec throws rather than sending ciphertext to Google.
          return CredentialCodec.decrypt(provider.clientSecret!)!;
        }
      }
    }

    return '';
  }

  List<String> get scopes {
    switch (this) {
      case LoginProviders.google:
        return [
          'https://www.googleapis.com/auth/userinfo.email',
          'https://www.googleapis.com/auth/userinfo.profile',
          'https://www.googleapis.com/auth/user.emails.read',
          'https://www.googleapis.com/auth/gmail.readonly',
        ];
      case LoginProviders.googleDrive:
        // 'drive' scope enables listing, downloading, and deleting files.
        // NOTE: 'drive' is a sensitive scope. For personal/internal use this
        // is fine. Public App Store distribution requires a Google security review.
        // Swap to 'drive.readonly' if you want to defer delete support.
        return [
          'https://www.googleapis.com/auth/userinfo.email',
          'https://www.googleapis.com/auth/userinfo.profile',
          'https://www.googleapis.com/auth/drive',
        ];
      case LoginProviders.azure:
        return ['openid', 'email'];
      case LoginProviders.outlook:
        return [
          'https://outlook.office.com/IMAP.AccessAsUser.All',
          'openid',
          'email',
          'profile',
          'offline_access',
        ];
    }
  }

  /// How long either profile lookup may take before sign-in gives up.
  static const Duration _profileTimeout = Duration(seconds: 20);

  /// Fetches Google user profile (email and userId).
  ///
  /// Tries Google People API first (`https://people.googleapis.com/v1/people/me`),
  /// and if that fails (e.g., HTTP 403 when People API is not enabled in Google Cloud Console),
  /// falls back to standard Google UserInfo API (`https://www.googleapis.com/oauth2/v2/userinfo`).
  static Future<GoogleUserProfile?> fetchGoogleProfile(
    String accessToken, {
    http.Client? client,
  }) async {
    // A stalled Google endpoint would otherwise hang sign-in indefinitely.
    // Both bounds are needed: connectionTimeout aborts the socket setup at the
    // transport, and the per-request timeout below covers a connection that
    // opens and then goes quiet.
    final httpClient =
        client ?? IOClient(HttpClient()..connectionTimeout = _profileTimeout);
    final shouldCloseClient = client == null;

    try {
      // 1. Attempt People API
      try {
        final peopleResponse = await httpClient
            .get(
              Uri.parse(
                "https://people.googleapis.com/v1/people/me?personFields=emailAddresses",
              ),
              headers: {"Authorization": "Bearer $accessToken"},
            )
            .timeout(_profileTimeout);

        if (peopleResponse.statusCode == 200) {
          final userData =
              jsonDecode(peopleResponse.body) as Map<String, dynamic>;
          final resourceName = userData['resourceName'] as String?;
          final emails = userData['emailAddresses'] as List?;

          if (resourceName != null && emails != null && emails.isNotEmpty) {
            final userId = resourceName.split("/").last;
            final primaryEmailObj = emails.firstWhere(
              (e) => (e['metadata']?['primary'] ?? false) == true,
              orElse: () => emails.first,
            );
            final email = primaryEmailObj['value'] as String?;

            if (userId.isNotEmpty && email != null && email.isNotEmpty) {
              return GoogleUserProfile(userId: userId, email: email);
            }
          }
        } else {
          AppLogger(null).w(
            'Google People API returned status ${peopleResponse.statusCode}. Falling back to UserInfo API...',
          );
        }
      } catch (e) {
        AppLogger(null).w(
          'Google People API request failed: $e. Falling back to UserInfo API...',
        );
      }

      // 2. Fallback to standard UserInfo API (does not require People API enabled in GCP Console)
      try {
        final userInfoResponse = await httpClient
            .get(
              Uri.parse("https://www.googleapis.com/oauth2/v2/userinfo"),
              headers: {"Authorization": "Bearer $accessToken"},
            )
            .timeout(_profileTimeout);

        if (userInfoResponse.statusCode == 200) {
          final userData =
              jsonDecode(userInfoResponse.body) as Map<String, dynamic>;
          final userId = userData['id'] as String?;
          final email = userData['email'] as String?;

          if (userId != null &&
              userId.isNotEmpty &&
              email != null &&
              email.isNotEmpty) {
            AppLogger(null).i(
              'Successfully fetched Google profile via UserInfo API fallback.',
            );
            return GoogleUserProfile(userId: userId, email: email);
          }
        } else {
          AppLogger(null).e(
            'Google UserInfo API error (${userInfoResponse.statusCode}): ${userInfoResponse.body}',
          );
        }
      } catch (e) {
        AppLogger(null).e('Google UserInfo API request failed: $e');
      }

      return null;
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }
  }

  /// Initiates the Google Mail OAuth2 flow, fetches the user's profile,
  /// and creates a [Collection] of type `email` with scanner `email.gmail`.
  static Future<Collection?> handleGoogleMail(
    BuildContext context, {
    Collection? existing,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Gmail is only supported on the desktop version of this app.',
          ),
        ),
      );
      return null;
    }

    try {
      final appDataDir = MainApp.appDataDirectory.valueOrNull;
      if (appDataDir == null) {
        throw Exception(
          'App data directory not initialized. Please restart the app.',
        );
      }
      final oauthManager = DesktopOAuthManager(
        loginProvider: LoginProviders.google,
      );

      final client = await oauthManager.login();

      final profile = await fetchGoogleProfile(client.credentials.accessToken);
      if (profile == null) {
        AppLogger(null).e(
          'Failed to fetch Google profile from both People API and UserInfo API.',
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Failed to fetch Google profile. Ensure Google People API is enabled in your GCP Console.',
              ),
            ),
          );
        }
        return null;
      }
      final userId = profile.userId;
      final email = profile.email;

      final collectionId = existing?.id ?? const Uuid().v4().toString();
      final extractionRoot = '$appDataDir/files/email/$collectionId';

      final collection = Collection(
        id: collectionId,
        name: email,
        path: "$appDataDir/files/email/$email",
        localCopyPath: extractionRoot,
        type: "email",
        scanner: AppConstants.scannerEmailGmail,
        scanStatus: "pending",
        oauthService: "google",
        accessToken: client.credentials.accessToken,
        refreshToken: client.credentials.refreshToken,
        idToken: client.credentials.idToken,
        userId: userId,
        expiration: client.credentials.expiration,
        needsReAuth: false,
      );

      final repo = CollectionRepository(DatabaseManager.instance.database!);
      if (existing != null) {
        await repo.updateCollection(collection);
      } else {
        await repo.addCollection(collection);
      }

      // Notify the email collections list to refresh
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand("email"),
      );

      return collection;
    } catch (e, stack) {
      AppLogger(null).e('Gmail OAuth failed', error: e, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Gmail sign-in failed. Please try again.'),
          ),
        );
      }
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Google Drive handler (new)
  // ---------------------------------------------------------------------------

  /// Initiates the Google Drive OAuth2 flow, fetches the user's Google profile,
  /// and creates (or updates) a [Collection] of type `file` with scanner
  /// `file.gdrive`.
  ///
  /// [rootFolderId] defaults to `'root'` (the user's entire Drive). Pass a
  /// specific Drive folder ID to scope the collection to a subfolder. This can
  /// be changed later when the user picks a folder from the picker UI.
  ///
  /// [existing] allows re-authorising an existing collection (token refresh /
  /// re-auth after `needsReAuth == true`).
  ///
  /// Returns the saved [Collection] on success, or `null` on failure.
  static Future<Collection?> handleGoogleDrive(
    BuildContext context, {
    Collection? existing,
    String rootFolderId = 'root',
    bool downloadLocalCopy = true,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Google Drive is only supported on the desktop version of this app.',
          ),
        ),
      );
      return null;
    }

    try {
      final oauthManager = DesktopOAuthManager(
        loginProvider: LoginProviders.googleDrive,
      );

      final client = await oauthManager.login();

      final profile = await fetchGoogleProfile(client.credentials.accessToken);
      if (profile == null) {
        AppLogger(null).e(
          'Failed to fetch Google profile from both People API and UserInfo API.',
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Failed to fetch Google profile. Ensure Google People API is enabled in your GCP Console.',
              ),
            ),
          );
        }
        return null;
      }
      final userId = profile.userId;
      final email = profile.email;

      final collectionId = existing?.id ?? const Uuid().v4().toString();

      final collection = Collection(
        id: collectionId,
        name: email,
        // 'path' stores the Drive root folder ID for this collection.
        // 'root' refers to the user's entire Drive. The folder picker UI
        // (Phase 9) can update this to a specific folder ID.
        path: rootFolderId,
        type: 'file',
        scanner: AppConstants.scannerFileGDrive,
        scanStatus: 'pending',
        oauthService: 'google',
        accessToken: client.credentials.accessToken,
        refreshToken: client.credentials.refreshToken,
        idToken: client.credentials.idToken,
        userId: userId,
        expiration: client.credentials.expiration,
        needsReAuth: false,
        downloadLocalCopy: downloadLocalCopy,
      );

      final repo = CollectionRepository(DatabaseManager.instance.database!);
      if (existing != null) {
        await repo.updateCollection(collection);
      } else {
        await repo.addCollection(collection);
      }

      // Notify the file collections list to refresh
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand('file'),
      );

      // Start the scanner immediately
      ScannerManager.getInstance().startScanner(collection);

      return collection;
    } catch (e, stack) {
      AppLogger(
        null,
      ).e('Google Drive OAuth failed', error: e, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Google Drive sign-in failed. Please try again.'),
          ),
        );
      }
      return null;
    }
  }

  /// Initiates the Outlook Mail OAuth2 flow and creates a [Collection]
  /// of type `email` with scanner `email.outlook`.
  static Future<Collection?> handleOutlookMail(
    BuildContext context, {
    Collection? existing,
  }) async {
    if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Outlook is only supported on the desktop version of this app.',
          ),
        ),
      );
      return null;
    }

    try {
      final appDataDir = MainApp.appDataDirectory.valueOrNull;
      if (appDataDir == null) {
        throw Exception(
          'App data directory not initialized. Please restart the app.',
        );
      }
      final oauthManager = DesktopOAuthManager(
        loginProvider: LoginProviders.outlook,
      );

      final client = await oauthManager.login(
        customParameters: {
          'prompt': 'select_account',
          'domain_hint': 'consumers',
        },
      );
      final credentials = client.credentials;
      String? email;
      String? userId;

      // Extract user info from the ID token if available (OIDC)
      if (credentials.idToken != null) {
        try {
          final payload = credentials.idToken!.split('.')[1];
          // Use base64Url.normalize to fix padding if necessary, then decode
          final normalizedPayload = base64Url.normalize(payload);
          final decodedPayload = utf8.decode(
            base64Url.decode(normalizedPayload),
          );
          final claims = jsonDecode(decodedPayload) as Map<String, dynamic>;
          final preferred = claims['preferred_username'] as String?;
          final mail = claims['email'] as String?;
          final upn = claims['upn'] as String?;

          // Prioritize preferred_username/UPN for IMAP as they are more likely to correspond
          // to the actual mailbox than an external 'email' claim.
          email = preferred ?? mail ?? upn;

          // Special case: if the identity appears to be an external one but there is
          // a Microsoft-hosted alias, favor the alias to ensure IMAP authentication works.
          if (email != null &&
              (email.endsWith('@gmail.com') || email.endsWith('@yahoo.com'))) {
            if (preferred != null &&
                !preferred.endsWith('@gmail.com') &&
                !preferred.endsWith('@yahoo.com')) {
              email = preferred;
            } else if (upn != null &&
                !upn.endsWith('@gmail.com') &&
                !upn.endsWith('@yahoo.com')) {
              email = upn;
            }
          }
          userId = claims['oid'] ?? claims['sub'] as String?;
          AppLogger(null).s("Outlook identity resolved: $email (ID: $userId)");
        } catch (e) {
          AppLogger(null).w('Failed to parse id_token from Azure: $e');
        }
      }

      // If OIDC info is missing, fallback to Microsoft Graph (though this may
      // fail now that we've removed the Graph scope which was causing conflicts).
      if (email == null || userId == null) {
        final response = await http.get(
          Uri.parse("https://graph.microsoft.com/v1.0/me"),
          headers: {
            "Authorization": "Bearer ${client.credentials.accessToken}",
          },
        );

        if (response.statusCode == 200) {
          final userData = jsonDecode(response.body) as Map<String, dynamic>;
          email ??=
              userData['mail'] ?? userData['userPrincipalName'] as String?;
          userId ??= userData['id'] as String?;
        } else {
          AppLogger(null).e(
            'Failed to fetch Outlook profile from id_token and Graph API error (${response.statusCode}): ${response.body}',
          );
        }
      }

      if (email == null || userId == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Failed to fetch Outlook profile information. Please try again.',
              ),
            ),
          );
        }
        return null;
      }

      final collectionId = existing?.id ?? const Uuid().v4().toString();
      final extractionRoot = '$appDataDir/files/email/$collectionId';

      final collection = Collection(
        id: collectionId,
        name: email,
        path: email, // Root path for IMAP scanner is the email address
        localCopyPath: extractionRoot,
        type: "email",
        scanner: AppConstants.scannerEmailOutlook,
        scanStatus: "pending",
        oauthService: "outlook",
        accessToken: client.credentials.accessToken,
        refreshToken: client.credentials.refreshToken,
        idToken: client.credentials.idToken,
        userId: userId,
        expiration: client.credentials.expiration,
        needsReAuth: false,
      );

      final repo = CollectionRepository(DatabaseManager.instance.database!);
      if (existing != null) {
        await repo.updateCollection(collection);
      } else {
        await repo.addCollection(collection);
      }

      // Notify the email collections list to refresh
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand("email"),
      );

      return collection;
    } catch (e, stack) {
      AppLogger(null).e('Outlook OAuth failed', error: e, stackTrace: stack);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Outlook sign-in failed. Please try again.'),
          ),
        );
      }
      return null;
    }
  }
}
