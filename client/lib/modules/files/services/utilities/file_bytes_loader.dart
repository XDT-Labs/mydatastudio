import 'dart:io' as io;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Loads the raw bytes of [file] from local disk or Google Drive.
///
/// Shared by the embedding and description isolates so both read a file's
/// contents the same way instead of duplicating GDrive token-refresh and
/// download logic.
class FileBytesLoader {
  static Future<List<int>?> load(
    File file,
    DatabaseRepository repo,
    AppLogger logger,
  ) {
    if (file.path.startsWith('gdrive://')) {
      return _loadFromGDrive(file, repo, logger);
    }
    return _loadFromDisk(file, logger);
  }

  static Future<List<int>?> _loadFromDisk(File file, AppLogger logger) async {
    final ioFile = io.File(file.path);
    if (!ioFile.existsSync()) {
      logger.w("File not found: ${file.path}");
      return null;
    }
    return ioFile.readAsBytes();
  }

  static Future<List<int>?> _loadFromGDrive(
    File file,
    DatabaseRepository repo,
    AppLogger logger,
  ) async {
    final collection = await repo.getCollection(file.collectionId);
    if (collection == null) {
      logger.w(
        "Collection not found for GDrive file: ${file.path}. Skipping.",
      );
      return null;
    }

    final fileId = file.path.replaceFirst('gdrive://', '');

    // Refresh token if needed
    String? accessToken = collection.accessToken;
    final now = DateTime.now().toUtc();
    final nearExpiry =
        collection.expiration == null ||
        now.isAfter(
          collection.expiration!.subtract(const Duration(minutes: 5)),
        );

    if (nearExpiry &&
        collection.accessToken != null &&
        collection.refreshToken != null) {
      try {
        final result = await GoogleAuthService.refreshTokens(
          accessToken: collection.accessToken!,
          refreshToken: collection.refreshToken!,
          db: repo.db,
        );
        accessToken = result.accessToken;
      } on GoogleAuthException catch (e) {
        // The refresh token itself is dead (revoked, or issued under an
        // OAuth client that's since been deleted/rotated) — no retry will
        // ever fix this. Flag the collection so the app's existing
        // needsReAuth prompt (see auth_dialog_manager.dart) tells the user
        // to reconnect, instead of this failing silently in the background
        // on every file forever.
        logger.e("GDrive token refresh failed: $e");
        await _flagNeedsReAuth(collection, repo, logger);
        return null;
      } catch (e) {
        // Anything else (not configured, network blip) is worth retrying
        // later — don't force a reconnect for a transient failure.
        logger.e("GDrive token refresh failed: $e");
        return null;
      }
    }

    if (accessToken == null) {
      logger.w("No access token for GDrive file: ${file.path}");
      return null;
    }

    final driveApi = drive.DriveApi(
      AuthenticatedHttpClient.bearer(accessToken),
    );

    try {
      final media =
          await driveApi.files
                  .get(fileId, downloadOptions: drive.DownloadOptions.fullMedia)
                  .timeout(const Duration(seconds: 30))
              as drive.Media;
      return await http.ByteStream(media.stream).toBytes().timeout(
        const Duration(minutes: 5),
      );
    } catch (e) {
      logger.e("Error downloading GDrive file: $e");
      return null;
    }
  }

  static Future<void> _flagNeedsReAuth(
    Collection collection,
    DatabaseRepository repo,
    AppLogger logger,
  ) async {
    try {
      await CollectionRepository(repo.db).markNeedsReAuth(collection.id);
    } catch (e) {
      logger.w("Failed to flag collection needsReAuth: $e");
    }
  }
}
