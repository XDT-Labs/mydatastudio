import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/files_constants.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/services/batch_action_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

void main() {
  group('BatchActionService', () {
    test('deleteSelected deselects all items upon completion', () async {
      final service = BatchActionService.instance;
      SelectionService.instance.selectAll(['f1', 'f2']);
      expect(SelectionService.instance.selectedIds.value, containsAll(['f1', 'f2']));

      await service.deleteSelected({'f1', 'f2'});

      expect(SelectionService.instance.selectedIds.value, isEmpty);
    });

    test('addToAlbum deselects all items upon completion', () async {
      final service = BatchActionService.instance;
      SelectionService.instance.selectAll(['f1']);
      expect(SelectionService.instance.selectedIds.value, contains('f1'));

      await service.addToAlbum({'f1'}, 'album-1');

      expect(SelectionService.instance.selectedIds.value, isEmpty);
    });
  });

  group('BatchActionService.deleteSelected DB effect', () {
    // deleteSelected must hide photos from the gallery (is_hidden = 1)
    // without touching is_deleted, which scanners own and clear on every
    // rescan. Writing is_deleted here would resurrect the old "soft delete
    // gets undone by the next sync" bug this feature exists to fix.
    TestWidgetsFlutterBinding.ensureInitialized();

    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp(
        'mydatastudio_batch_action_',
      );

      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            return tempDir.path;
          });

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;

      await CollectionRepository(db).addCollection(
        Collection(
          id: 'col-1',
          name: 'Test',
          path: tempDir.path,
          type: 'local',
          scanner: 'file.local',
          scanStatus: 'idle',
          needsReAuth: false,
          localCopyPath: tempDir.path,
        ),
      );

      await FileDesktopRepository(db).create(
        File(
          id: 'file-1',
          name: 'photo.jpg',
          path: 'photo.jpg',
          parent: '',
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          collectionId: 'col-1',
          contentType: FilesConstants.mimeTypeImage,
          size: 3,
          isDeleted: false,
        ),
      );
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('sets is_hidden and leaves is_deleted untouched', () async {
      await BatchActionService.instance.deleteSelected({'file-1'});

      final rows = await db.select(
        "SELECT is_deleted, is_hidden FROM files WHERE id = ?",
        ['file-1'],
      );

      expect(rows.first['is_hidden'], 1);
      expect(rows.first['is_deleted'], 0);
    });
  });
}
