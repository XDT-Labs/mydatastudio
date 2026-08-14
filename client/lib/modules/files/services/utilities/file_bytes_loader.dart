import 'dart:io' as io;
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/file_sources/google_drive/google_auth_service.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// The outcome of a byte load, which is not the same question as "did I get
/// bytes".
///
/// A caller has to know *why* a read failed, because the two reasons call for
/// opposite responses. A file on an unmounted NAS or behind an expired token
/// will read fine later, so the right move is to back the whole source off and
/// keep the file's retry budget intact. A file that can never be read as bytes
/// — a Google Doc, which is not stored as a file at all — will fail exactly
/// the same way on every future pass, and treating it as an outage stalls
/// every *other* file in that collection behind it.
///
/// [FileBytesLoader.load] flattens this to a nullable list for the callers
/// that only need the bytes.
class FileBytes {
  final List<int>? bytes;

  /// True when no future attempt can succeed.
  final bool permanent;

  const FileBytes.ok(List<int> this.bytes) : permanent = false;
  const FileBytes.transient() : bytes = null, permanent = false;
  const FileBytes.permanent() : bytes = null, permanent = true;

  bool get ok => bytes != null;
}

/// Loads the raw bytes of [file] from local disk or Google Drive.
///
/// Shared by the embedding and description isolates so both read a file's
/// contents the same way instead of duplicating GDrive token-refresh and
/// download logic.
class FileBytesLoader {
  /// The bytes, or null on any failure.
  ///
  /// Kept for callers that handle images, where every failure is effectively
  /// transient — an unreadable photo is a broken file, not a format that has
  /// no bytes. Use [loadDetailed] where the difference matters.
  static Future<List<int>?> load(
    File file,
    DatabaseRepository repo,
    AppLogger logger,
  ) async => (await loadDetailed(file, repo, logger)).bytes;

  static Future<FileBytes> loadDetailed(
    File file,
    DatabaseRepository repo,
    AppLogger logger,
  ) async {
    // Checked before any network call, because this is a property of the
    // format rather than of the request. Google Docs, Sheets and Slides are
    // not stored as files; Drive's media endpoint refuses them by design with
    // "Only files with binary content can be downloaded", and it will refuse
    // them identically forever. They need `files.export` with a target
    // format, which is not implemented (search plan §18k).
    if (isGoogleNativeFormat(file.contentType)) {
      logger.d(
        'Google Workspace file has no downloadable bytes: ${file.name} '
        '(${file.contentType}) — needs export, see §18k',
      );
      return const FileBytes.permanent();
    }
    if (file.path.startsWith('gdrive://')) {
      final bytes = await _loadFromGDrive(file, repo, logger);
      return bytes == null ? const FileBytes.transient() : FileBytes.ok(bytes);
    }
    final bytes = await _loadFromDisk(file, logger);
    return bytes == null ? const FileBytes.transient() : FileBytes.ok(bytes);
  }

  /// Google Workspace formats, which have no byte representation to download.
  ///
  /// Deliberately narrow. Other 403s from Drive — `userRateLimitExceeded`
  /// most of all — are transient, so classifying by *status code* would retire
  /// files during a rate limit. The content type is structural and cannot be
  /// mistaken for a temporary condition.
  static bool isGoogleNativeFormat(String? mimeType) =>
      mimeType != null &&
      mimeType.startsWith('application/vnd.google-apps.') &&
      mimeType != 'application/vnd.google-apps.folder';

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
      logger.w("Collection not found for GDrive file: ${file.path}. Skipping.");
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
      return await http.ByteStream(
        media.stream,
      ).toBytes().timeout(const Duration(minutes: 5));
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
