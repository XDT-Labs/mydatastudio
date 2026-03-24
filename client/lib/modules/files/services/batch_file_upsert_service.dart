import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/file.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';

import 'package:mydatatools/services/rx_service.dart';
import 'package:flutter/material.dart';

class BatchFileUpsertService extends RxService<BatchFileUpsertServiceCommand, List<File>> {
  static final BatchFileUpsertService _singleton = BatchFileUpsertService();
  static get instance => _singleton;

  @override
  Future<List<File>> invoke(BatchFileUpsertServiceCommand command) async {
    isLoading.add(true);

    FileDesktopRepository repo = FileDesktopRepository(command.database);

    try {
      await repo.upsertAll(command.files);
      sink.add(command.files);
    } catch (err) {
      debugPrint("Batch upsert failed: ${err.toString()}");
    }
    
    isLoading.add(false);
    return Future(() => command.files);
  }
}

class BatchFileUpsertServiceCommand implements RxCommand {
  List<File> files;
  AppDatabase database;
  BatchFileUpsertServiceCommand(this.files, this.database);
}
