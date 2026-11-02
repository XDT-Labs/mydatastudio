import 'package:mydatastudio/database_manager.dart';

/// Provider-neutral description of one item (file or folder) in a cloud drive.
class CloudFileEntry {
  final String id;
  final String name;
  final bool isFolder;

  /// Containing folder ids. Empty when the provider doesn't report parents
  /// (the scanner then falls back to the folder it was listing).
  final List<String> parentIds;
  final int? size;
  final String? mimeType;
  final DateTime? created;
  final DateTime? modified;
  final String? thumbnailLink;
  final String? webLink;

  /// SHA-256 as lowercase hex, only when the provider supplies one.
  final String? contentHash;

  /// False for items whose bytes can't be fetched as a plain file (e.g. Google
  /// Docs/Sheets, which would need an export). Folders are never downloadable.
  final bool isDownloadable;

  const CloudFileEntry({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.parentIds = const [],
    this.size,
    this.mimeType,
    this.created,
    this.modified,
    this.thumbnailLink,
    this.webLink,
    this.contentHash,
    this.isDownloadable = true,
  });
}

/// One page of listing results. [nextPageToken] is null on the last page.
class CloudFilePage {
  final List<CloudFileEntry> entries;
  final String? nextPageToken;

  const CloudFilePage(this.entries, {this.nextPageToken});
}

/// One change reported by a provider's change feed.
class CloudChange {
  final String id;

  /// The item was deleted or trashed at the source. [entry] is then usually
  /// null.
  final bool removed;

  /// Current metadata of an added/modified/moved item; null when [removed].
  final CloudFileEntry? entry;

  const CloudChange(this.id, {this.removed = false, this.entry});
}

/// One page of the change feed. Follow [nextPageCursor] while non-null; the
/// last page carries [newStartCursor], the position to store for the next run.
class CloudChangePage {
  final List<CloudChange> changes;
  final String? nextPageCursor;
  final String? newStartCursor;

  const CloudChangePage(
    this.changes, {
    this.nextPageCursor,
    this.newStartCursor,
  });
}

/// The provider rejected a stored change cursor (expired or invalid). The
/// scanner recovers with a full re-list.
class CloudCursorExpiredException implements Exception {
  final String message;

  const CloudCursorExpiredException([this.message = 'change cursor expired']);

  @override
  String toString() => 'CloudCursorExpiredException: $message';
}

/// Thrown by a [CloudFileApiFactory] when credentials can't be refreshed.
/// [needsReAuth] true means the refresh token is dead and the user must
/// reconnect (the scanner flags the collection); false is a transient failure.
class CloudAuthException implements Exception {
  final String message;
  final bool needsReAuth;

  const CloudAuthException(this.message, {this.needsReAuth = false});

  @override
  String toString() => 'CloudAuthException: $message';
}

/// What a [CloudFileApiFactory] gets to build an adapter inside the scan
/// isolate. Raw strings only — live clients can't cross isolate boundaries.
class CloudFileApiCredentials {
  final String accessToken;
  final String refreshToken;
  final DateTime? expiry;

  /// The isolate's own (read-only) connection, for providers that read their
  /// OAuth client config from settings while refreshing.
  final AppDatabase? db;

  const CloudFileApiCredentials({
    required this.accessToken,
    required this.refreshToken,
    this.expiry,
    this.db,
  });
}

/// Builds an authenticated [CloudFileApi] inside the scan isolate, refreshing
/// the access token first if the provider needs it. Each provider refreshes
/// differently, so this is where that lives. Must be a top-level or static
/// function so it can be sent to the isolate.
typedef CloudFileApiFactory =
    Future<CloudFileApi> Function(CloudFileApiCredentials credentials);

/// The small surface a cloud provider (Drive, Dropbox, OneDrive, Box...) has to
/// implement for the generic `CloudFileScanner`.
abstract class CloudFileApi {
  /// URI scheme used for `files.path` (`<scheme>://<id>`) and the local copy
  /// directory (`files/<scheme>/...`), e.g. `gdrive`.
  String get scheme;

  /// Lists the direct children of [folderId], one page at a time.
  Future<CloudFilePage> listChildren(String folderId, {String? pageToken});

  /// The change-feed position "now". Taken before a full walk so changes made
  /// during the walk are replayed by the next incremental run.
  Future<String> startCursor();

  /// Changes since [cursor], drive-wide, one page at a time (pass a page's
  /// `nextPageCursor` to continue). Throws [CloudCursorExpiredException] when
  /// the provider no longer accepts [cursor].
  Future<CloudChangePage> listChanges(String cursor);

  /// Metadata for one item, or null if it no longer exists.
  Future<CloudFileEntry?> getEntry(String id);

  /// Whether items of [mimeType] can be downloaded as plain bytes. Used to
  /// filter the download queue, which is built from stored rows.
  bool isDownloadableMimeType(String mimeType);

  /// Streams the item's bytes to [destPath] (parent directory already exists).
  Future<void> download(String id, String destPath);
}
