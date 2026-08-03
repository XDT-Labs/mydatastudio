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
      for (final f in targets) {
        final src = io.File(f.path);
        if (await src.exists()) {
          final destPath = p.join(saveDir, f.name);
          await src.copy(destPath);
        }
      }
    }
  }

  Future<void> deleteSelected(Set<String> fileIds) async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;
    
    for (String id in fileIds) {
      await db.execute("UPDATE files SET is_deleted = 1 WHERE id = ?", [id]);
    }
    SelectionService.instance.deselectAll();
  }

  Future<void> favoriteSelected(Set<String> fileIds) async {
    final db = DatabaseManager.instance.database;
    if (db == null) return;
    
    for (String id in fileIds) {
      await db.execute("UPDATE files SET is_favorite = 1 WHERE id = ?", [id]);
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
