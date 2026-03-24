import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/modules/files/services/repositories/folder_repository.dart';

class CleanupDeletedFilesServiceCommand {
  final String collectionId;
  final String path;
  final DateTime scanStartTime;
  final AppDatabase database;
  final bool recursive;
  final bool isCloud;
  final bool isFullScan;

  CleanupDeletedFilesServiceCommand(this.collectionId, this.path, this.scanStartTime, this.database, {this.recursive = true, this.isCloud = false, this.isFullScan = false});
}

class CleanupDeletedFilesService {
  AppLogger logger = AppLogger(null);
  
  static final CleanupDeletedFilesService _singleton = CleanupDeletedFilesService._();
  static CleanupDeletedFilesService get instance => _singleton;
  CleanupDeletedFilesService._();

  Future<int> invoke(CleanupDeletedFilesServiceCommand command) async {
    try {
      FileDesktopRepository fileRepo = FileDesktopRepository(command.database);
      FolderDesktopRepository folderRepo = FolderDesktopRepository(command.database);

      await fileRepo.markMissingAsDeleted(command.collectionId, command.path, command.scanStartTime, recursive: command.recursive, isCloud: command.isCloud, isFullScan: command.isFullScan);
      await folderRepo.deleteMissing(command.collectionId, command.path, command.scanStartTime, recursive: command.recursive, isCloud: command.isCloud, isFullScan: command.isFullScan);
      
      return 0;
    } catch (e) {
      logger.e('Failed to cleanup deleted files: $e');
      return 1;
    }
  }
}
