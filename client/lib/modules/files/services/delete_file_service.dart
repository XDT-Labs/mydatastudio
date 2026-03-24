import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
import 'package:mydatatools/services/rx_service.dart';
import 'package:flutter/material.dart';

class DeleteFileService extends RxService<DeleteFileServiceCommand, bool> {
  static final DeleteFileService _singleton = DeleteFileService._();
  static DeleteFileService get instance => _singleton;
  DeleteFileService._();

  @override
  Future<bool> invoke(DeleteFileServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    try {
      await repo.delete(command.file);
      sink.add(true);
      isLoading.add(false);
      return true;
    } catch (err) {
      debugPrint("Error deleting file from database: $err");
      isLoading.add(false);
      return false;
    }
  }
}

class DeleteFileServiceCommand implements RxCommand {
  final File file;
  final AppDatabase database;
  DeleteFileServiceCommand(this.file, this.database);
}
