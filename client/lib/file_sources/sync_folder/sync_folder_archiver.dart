import 'dart:io' as io;

import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/file_sources/sync_folder/file_evictor.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';
import 'package:path/path.dart' as p;

/// Keeps an archive copy of a cloud sync folder's files (iCloud Drive,
/// Dropbox, OneDrive, Google Drive, Box), as the API connectors do for theirs.
///
/// A sync folder alone is not a backup: the provider can evict, delete or
/// lose a file, and an online-only file isn't on this Mac at all. Copying
/// an online-only file makes macOS download it, so it is evicted again once
/// copied: the archive gains the file and the user's sync folder looks
/// exactly as it did.
class SyncFolderArchiver {
  SyncFolderArchiver({
    required this.archiveDir,
    required this.policy,
    required this.recordCopy,
    OnlineOnlyChecker? onlineOnly,
    FileEvictor? evictor,
    this.logger,
  }) : onlineOnly = onlineOnly ?? FfiOnlineOnlyChecker(),
       evictor = evictor ?? OsascriptFileEvictor();

  /// Where this collection's copies go, mirroring the folder's layout.
  final String archiveDir;
  final ContentPolicy policy;

  /// Stores the copy's path as the file's `local_path`.
  final Future<void> Function(String fileId, String localPath) recordCopy;
  final OnlineOnlyChecker onlineOnly;
  final FileEvictor evictor;
  final AppLogger? logger;

  /// Archives every file in [files] the policy covers whose copy is missing
  /// or older than the file. [rootPath] is the sync folder; each file's
  /// `path` is relative to it. Returns how many files were copied.
  Future<int> archiveAll(String rootPath, Iterable<File> files) async {
    var copied = 0;
    for (final f in files) {
      if (!policy.shouldDownload(f)) continue;
      try {
        if (await archive(rootPath, f)) copied++;
      } catch (e) {
        // One unreadable file (offline, permissions) must not stop the rest;
        // it is retried on the next scan.
        logger?.w('SyncFolderArchiver: could not copy ${f.path}: $e');
      }
    }
    return copied;
  }

  /// Copies one file when its archive copy is missing or stale. True when a
  /// copy was made.
  Future<bool> archive(String rootPath, File f) async {
    final source = p.join(rootPath, f.path);
    final dest = p.join(archiveDir, f.path);
    final destFile = io.File(dest);

    // The copy carries the file's modification time, so an unchanged file is
    // skipped without reading it (which would download an online-only one).
    if (destFile.existsSync() &&
        _sameSecond(destFile.lastModifiedSync(), f.dateLastModified)) {
      if (f.localPath != dest) await recordCopy(f.id, dest);
      return false;
    }

    final wasOnlineOnly = onlineOnly.isOnlineOnly(source);
    await destFile.parent.create(recursive: true);
    // Copy to a .part file and rename, so an interrupted copy is never taken
    // for a finished one.
    final part = io.File('$dest.part');
    try {
      await io.File(source).copy(part.path);
      await part.setLastModified(f.dateLastModified);
      await part.rename(dest);
    } catch (_) {
      if (part.existsSync()) part.deleteSync();
      rethrow;
    }
    if (wasOnlineOnly && !await evictor.evict(source)) {
      logger?.w('SyncFolderArchiver: could not return $source to online-only');
    }
    await recordCopy(f.id, dest);
    return true;
  }

  static bool _sameSecond(DateTime a, DateTime b) =>
      a.millisecondsSinceEpoch ~/ 1000 == b.millisecondsSinceEpoch ~/ 1000;
}
