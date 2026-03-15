import 'dart:io' as io;

import 'package:mydatatools/file_sources/file_source_file.dart';
import 'package:mydatatools/models/tables/collection.dart';

/// Abstract data-access contract for all file sources (local, Google Drive,
/// Dropbox, OneDrive, etc.).
///
/// **This interface is for UI actions only** (list, download, delete, open).
/// Background scanning is handled separately by [CollectionScanner] subclasses
/// (e.g. [LocalFileIsolate], [CloudFileIsolate]) which cannot hold a provider
/// reference across an isolate boundary.
///
/// To resolve the correct provider for a given [Collection] at runtime, use
/// [FileSourceRegistry.forCollection].
abstract class FileSourceProvider {
  /// Short identifier matching [AppConstants.scannerFile*] constants.
  /// Examples: `'local'`, `'gdrive'`, `'dropbox'`
  String get providerKey;

  /// The [Collection.scanner] string this provider handles.
  /// Examples: `'file.local'`, `'file.gdrive'`
  String get scannerType;

  /// Human-readable name shown in the UI.
  /// Examples: `'Local Files'`, `'Google Drive'`
  String get displayName;

  // ---------------------------------------------------------------------------
  // Browse
  // ---------------------------------------------------------------------------

  /// Lists the immediate children of [folderId] (or the collection root when
  /// [folderId] is null). Returns both files and folders as [FileSourceFile]s.
  ///
  /// Implementations should NOT recurse; recursion is the caller's
  /// responsibility (or the scanner's).
  Future<List<FileSourceFile>> listFolder(
    Collection collection, {
    String? folderId,
  });

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  /// Downloads [file] to [destPath] and returns a handle to the local file.
  ///
  /// For local providers this is a copy (or no-op when already at [destPath]).
  /// For cloud providers this streams the remote content to disk.
  Future<io.File> downloadFile(
    Collection collection,
    FileSourceFile file,
    String destPath,
  );

  /// Deletes [file] from the source.
  ///
  /// For local providers this removes the file from disk.
  /// For cloud providers this moves the file to the provider's trash.
  ///
  /// Returns `true` on success.
  Future<bool> deleteFile(Collection collection, FileSourceFile file);

  /// Opens [file] using the appropriate viewer.
  ///
  /// For local files this launches the system default app.
  /// For cloud files this opens the provider web URL.
  Future<void> openFile(Collection collection, FileSourceFile file);
}
