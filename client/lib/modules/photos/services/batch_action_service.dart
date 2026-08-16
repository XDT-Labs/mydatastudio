import 'dart:io' as io;
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/file_sources/file_source_file.dart';
import 'package:mydatastudio/file_sources/file_source_provider.dart';
import 'package:mydatastudio/file_sources/google_drive/google_drive_provider.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/services/utilities/system_trash.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:path/path.dart' as p;

class BatchActionService {
  static final BatchActionService _instance = BatchActionService._();
  static BatchActionService get instance => _instance;
  
  BatchActionService._();
  
  final PhotosRepository _repo = PhotosRepository();
  final AppLogger _logger = AppLogger(null);

  Future<void> downloadSingle(File file) async {
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Photo',
      fileName: file.name,
    );
    if (savePath != null) {
      final srcFile = io.File(file.path);
      if (await srcFile.exists()) {
        await srcFile.copy(savePath);
      }
    }
  }

  Future<void> downloadSelected(Set<String> fileIds) async {
    if (fileIds.isEmpty) return;
    if (fileIds.length == 1) {
      final allFiles = PhotosService.instance.sink.valueOrNull ?? [];
      final target = allFiles.cast<File?>().firstWhere((f) => f?.id == fileIds.first, orElse: () => null);
      if (target != null) {
        await downloadSingle(target);
        return;
      }
    }
    final saveDir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select export directory',
    );
    if (saveDir != null) {
      final allFiles = PhotosService.instance.sink.valueOrNull ?? [];
      final targets = allFiles.where((f) => fileIds.contains(f.id)).toList();
      final usedNames = <String, int>{};
      for (final f in targets) {
        final src = io.File(f.path);
        if (await src.exists()) {
          final baseName = p.basenameWithoutExtension(f.name);
          final ext = p.extension(f.name);

          String destFileName = f.name;
          if (usedNames.containsKey(f.name)) {
            final count = usedNames[f.name]! + 1;
            usedNames[f.name] = count;
            destFileName = '$baseName ($count)$ext';
          } else {
            usedNames[f.name] = 1;
          }

          final destPath = p.join(saveDir, destFileName);
          await src.copy(destPath);
        }
      }
    }
  }

  /// Hides the selected photos from the gallery by setting `is_hidden`.
  /// This is a gallery-only, user-owned flag — it never touches
  /// `is_deleted`, which scanners own and clear on every rescan. The
  /// original files stay on disk and in their source (Drive, Gmail, PST,
  /// etc.); they simply stop showing up in the Photos module.
  /// Hides the selected photos from the gallery. Nothing is removed from disk
  /// or from the source — see [deleteSelectedFiles] for that.
  Future<void> hideSelected(Set<String> fileIds) => deleteSelected(fileIds);

  /// Removes the selected photos from the app, and from the source wherever the
  /// app can reach it.
  ///
  /// Order matters. The database row is marked first, so a failure part way
  /// through leaves photos out of the app rather than leaving the user staring
  /// at photos they just deleted. `is_user_deleted` is what makes that stick:
  /// `is_deleted` is scanner-owned and a manual Sync runs with `force: true`,
  /// which bypasses the "already imported" skip and would re-create every
  /// attachment.
  ///
  /// What "delete" reaches depends on the source, which is why the dialog says
  /// so before this runs:
  ///  - local originals go to the system Trash, recoverable
  ///  - Drive files are marked trashed through the Drive API, recoverable
  ///  - email attachments cannot be removed from the message, so only the app's
  ///    extracted copy goes
  ///
  /// A file that cannot be trashed is left on disk on purpose. It has already
  /// left the app, and quietly hard-deleting something the user was told would
  /// be recoverable is the worse failure.
  Future<void> deleteSelectedFiles(
    Set<String> fileIds, {
    SystemTrash? trash,
    FileSourceProvider Function(Collection)? providerFor,
    PhotosRepository? repo,
  }) async {
    if (fileIds.isEmpty) return;
    final db = DatabaseManager.instance.database;
    if (db == null) return;

    final systemTrash = trash ?? SystemTrash();
    final repository = repo ?? _repo;
    final files = await repository.filesByIds(fileIds);

    await db.executeBatch(
      "UPDATE files SET is_user_deleted = 1 WHERE id = ?",
      fileIds.map((id) => [id]).toList(),
    );

    // A selection is drawn from a handful of sources at most, so looking the
    // collection up per file turns one query into one-per-photo against the
    // single main-isolate connection, where they queue anyway. Cached by id,
    // a hundred photos from one source cost one query. Nulls are cached too —
    // a collection that has gone stays gone for the rest of the batch.
    final collections = <String, Collection?>{};

    // Drive files are gathered per collection rather than trashed as they come
    // up: deleteFiles builds one authenticated client for the batch, where a
    // call per file would re-read the token every time and, inside the refresh
    // threshold, refresh it every time.
    final drivePerCollection = <String, List<FileSourceFile>>{};

    for (final file in files) {
      if (!collections.containsKey(file.collectionId)) {
        collections[file.collectionId] =
            await repository.collectionFor(file.collectionId);
      }
      final collection = collections[file.collectionId];
      final scanner = collection?.scanner ?? '';

      if (scanner == AppConstants.scannerFileGDrive && collection != null) {
        drivePerCollection.putIfAbsent(collection.id, () => []).add(
              FileSourceFile(
                // Drive's own id, not ours — it lives in the path as
                // `gdrive://<id>`, the same way rx_files_page reads it.
                id: file.path.replaceFirst('gdrive://', ''),
                name: file.name,
                mimeType: file.contentType,
                isFolder: false,
              ),
            );
        continue;
      }

      // Local originals, and the app's extracted copy of an email attachment.
      // Both are real files on disk that the app is allowed to move.
      final path = file.localPath?.isNotEmpty == true ? file.localPath! : file.path;
      if (path.isNotEmpty && !path.startsWith('gdrive://')) {
        await systemTrash.moveToTrash(path);
      }
    }

    for (final entry in drivePerCollection.entries) {
      final collection = collections[entry.key]!;
      final provider = providerFor?.call(collection) ?? GoogleDriveProvider();
      try {
        final trashed = await provider.deleteFiles(collection, entry.value);
        if (trashed < entry.value.length) {
          // The rows stay marked — the photos have left the app either way,
          // and that is the documented order. But a file still sitting in
          // Drive after the user asked for it gone is not something to pass
          // over in silence.
          _logger.w(
            'Trashed $trashed of ${entry.value.length} in ${collection.name}; '
            'the rest are still in Drive',
          );
        }
      } catch (e) {
        // deleteFiles counts its own per-file failures; reaching here means
        // the whole batch went, which is worth one line rather than silence.
        _logger.w('Could not trash Drive files for ${collection.name}: $e');
      }
    }

    await PhotosService.instance.refresh();
    SelectionService.instance.deselectAll();
  }

  Future<void> deleteSelected(Set<String> fileIds) async {
    if (fileIds.isEmpty) return;
    final db = DatabaseManager.instance.database;
    if (db != null) {
      final paramSets = fileIds.map((id) => [id]).toList();
      await db.executeBatch("UPDATE files SET is_hidden = 1 WHERE id = ?", paramSets);
      await PhotosService.instance.refresh();
    }
    SelectionService.instance.deselectAll();
  }

  Future<void> favoriteSelected(Set<String> fileIds) async {
    if (fileIds.isEmpty) return;
    final db = DatabaseManager.instance.database;
    if (db != null) {
      final paramSets = fileIds.map((id) => [id]).toList();
      await db.executeBatch("UPDATE files SET is_favorite = 1 WHERE id = ?", paramSets);
      await PhotosService.instance.refresh();
    }
  }

  Future<void> addToAlbum(Set<String> fileIds, String albumId) async {
    for (String fileId in fileIds) {
      await _repo.addFileToAlbum(fileId, albumId);
    }
    SelectionService.instance.deselectAll();
  }

  Future<void> removeFromAlbum(Set<String> fileIds, String albumId) async {
    for (String fileId in fileIds) {
      await _repo.removeFileFromAlbum(fileId, albumId);
    }
  }
}
