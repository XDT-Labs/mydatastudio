import 'dart:io' as io;
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
