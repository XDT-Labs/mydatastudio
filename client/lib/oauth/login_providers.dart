import 'dart:convert';
import 'dart:io';

import 'package:mydatatools/app_constants.dart';
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/main.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/oauth/desktop_oauth_manager.dart';
import 'package:mydatatools/repositories/collection_repository.dart';
import 'package:mydatatools/scanners/scanner_manager.dart';
import 'package:mydatatools/services/get_collections_service.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

// ignore: constant_identifier_names
enum LoginProviders { google, googleDrive, azure }

///
/// Based on this stackoverflow answer
/// https://stackoverflow.com/questions/68716993/google-microsoft-oauth2-login-flow-flutter-desktop-macos-windows-linux
extension LoginProviderExtension on LoginProviders {
  String get key {
    switch (this) {
      case LoginProviders.google:
        return 'google';
      case LoginProviders.googleDrive:
        return 'google'; // same identity provider, different scopes
      case LoginProviders.azure:
        return 'azure';
    }
  }

  String get authorizationEndpoint {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return "https://accounts.google.com/o/oauth2/v2/auth";
      case LoginProviders.azure:
        return "https://login.microsoftonline.com/common/oauth2/v2.0/authorize";
    }
  }

  String get tokenEndpoint {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return "https://oauth2.googleapis.com/token";
      case LoginProviders.azure:
        return "https://login.microsoftonline.com/common/oauth2/v2.0/token";
    }
  }

  /// OAuth client ID.
  /// Evaluation happens at compile-time via --dart-define or --dart-define-from-file.
  String get clientId {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return const String.fromEnvironment('GOOGLE_CLIENT_ID');
      case LoginProviders.azure:
        return const String.fromEnvironment('AZURE_CLIENT_ID');
    }
  }

  /// OAuth client secret.
  /// Evaluation happens at compile-time via --dart-define or --dart-define-from-file.
  String get clientSecret {
    switch (this) {
      case LoginProviders.google:
      case LoginProviders.googleDrive:
        return const String.fromEnvironment('GOOGLE_CLIENT_SECRET');
      case LoginProviders.azure:
        return "";
    }
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
        throw Exception('App data directory not initialized. Please restart the app.');
      }
      final oauthManager = DesktopOAuthManager(
        loginProvider: LoginProviders.google,
      );

      final client = await oauthManager.login();

      // Fetch Google profile to get user email & resource name
      final peopleResponse = await http.get(
        Uri.parse(
          "https://people.googleapis.com/v1/people/me?personFields=emailAddresses",
        ),
        headers: {
          "Authorization": "Bearer ${client.credentials.accessToken}",
        },
      );

      if (peopleResponse.statusCode != 200) {
        AppLogger(null).e(
          'Google People API error (${peopleResponse.statusCode}): ${peopleResponse.body}',
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Failed to fetch Google profile. Please try again.',
              ),
            ),
          );
        }
        return null;
      }

      final userData = jsonDecode(peopleResponse.body) as Map<String, dynamic>;
      final userId = (userData['resourceName'] as String).split("/")[1];
      final emails = userData['emailAddresses'] as List;
      final email =
          emails.firstWhere(
            (e) => (e['metadata']['primary'] ?? false) == true,
          )['value'] as String;

      final collectionId = existing?.id ?? const Uuid().v4().toString();

      final collection = Collection(
        id: collectionId,
        name: email,
        path: "$appDataDir/files/email/$email",
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

      if (existing != null) {
        await CollectionRepository().updateCollection(collection);
      } else {
        await CollectionRepository().addCollection(collection);
      }

      // Notify the email collections list to refresh
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand("email"),
      );

      return collection;
    } catch (e, stack) {
      AppLogger(null).e('Gmail OAuth failed: $e\n$stack');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gmail sign-in failed: $e')),
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

      // Fetch Google profile to get user email & resource name
      final peopleResponse = await http.get(
        Uri.parse(
          "https://people.googleapis.com/v1/people/me?personFields=emailAddresses",
        ),
        headers: {
          "Authorization": "Bearer ${client.credentials.accessToken}",
        },
      );

      if (peopleResponse.statusCode != 200) {
        AppLogger(null).e(
          'Google People API error (${peopleResponse.statusCode}): ${peopleResponse.body}',
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Failed to fetch Google profile. Please try again.',
              ),
            ),
          );
        }
        return null;
      }

      final userData =
          jsonDecode(peopleResponse.body) as Map<String, dynamic>;
      final userId = (userData['resourceName'] as String).split("/")[1];
      final emails = userData['emailAddresses'] as List;
      final email =
          emails.firstWhere(
            (e) => (e['metadata']['primary'] ?? false) == true,
          )['value'] as String;

      final collectionId = existing?.id ?? const Uuid().v4().toString();

      final collection = Collection(
        id: collectionId,
        name: 'Google Drive ($email)',
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
      );

      if (existing != null) {
        await CollectionRepository().updateCollection(collection);
      } else {
        await CollectionRepository().addCollection(collection);
      }

      // Notify the file collections list to refresh
      GetCollectionsService.instance.invoke(
        GetCollectionsServiceCommand('file'),
      );

      // Start the scanner immediately
      ScannerManager.getInstance().startScanner(collection);

      return collection;
    } catch (e, stack) {
      AppLogger(null).e('Google Drive OAuth failed: $e\n$stack');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Google Drive sign-in failed: $e')),
        );
      }
      return null;
    }
  }

}

