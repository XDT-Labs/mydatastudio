import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';

class BatchActionService {
  static final BatchActionService _instance = BatchActionService._();
  static BatchActionService get instance => _instance;
  
  BatchActionService._();
  
  final PhotosRepository _repo = PhotosRepository();

  Future<void> downloadSelected(Set<String> fileIds) async {
    // File copying logic would go here
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
