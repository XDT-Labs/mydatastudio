import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/photos/services/photos_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// A manual Sync runs the scanners with `force: true`, which bypasses the
/// "already imported this message" skip and re-upserts everything. `is_deleted`
/// cannot survive that — the upsert resets it — so a user delete needs a flag
/// no scanner writes. These tests pin that down.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('is_user_deleted', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late String collectionId;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_userdel_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;

      collectionId = const Uuid().v4();
      await CollectionRepository(db).addCollection(
        Collection(
          id: collectionId,
          name: 'Photos',
          path: '/photos',
          type: 'file',
          scanner: 'local',
          needsReAuth: false,
          scanStatus: 'idle',
        ),
      );
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try { tempDir.deleteSync(recursive: true); } catch (_) {}
      }
    });

    File photo(String id, {bool userDeleted = false}) => File(
          id: id,
          name: '$id.jpg',
          path: '/photos/$id.jpg',
          parent: '/photos',
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: collectionId,
          contentType: 'image/jpeg',
          size: 1024,
          isDeleted: false,
          isUserDeleted: userDeleted,
        );

    test('the column exists and round-trips through the model', () async {
      final columns = (await db.select('PRAGMA table_info(files)'))
          .map((r) => r['name'] as String).toSet();
      expect(columns, contains('is_user_deleted'));

      await FileDesktopRepository(db).create(photo('a', userDeleted: true));
      final rows = await db.select('SELECT * FROM files WHERE id = ?', ['a']);
      expect(File.fromDbMap(rows.first).isUserDeleted, isTrue);
    });

    test('a user-deleted photo leaves the gallery', () async {
      final repo = FileDesktopRepository(db);
      await repo.create(photo('keep'));
      await repo.create(photo('gone'));
      await db.execute(
        'UPDATE files SET is_user_deleted = 1 WHERE id = ?', ['gone']);

      final visible = (await PhotosRepository().photos()).map((f) => f.id);
      expect(visible, contains('keep'));
      expect(visible, isNot(contains('gone')));
    });

    // The regression that matters: clicking Sync must not undo a delete.
    test('stays deleted through the scanner upsert a manual Sync runs',
        () async {
      final repo = FileDesktopRepository(db);
      await repo.create(photo('gone'));
      await db.execute(
        'UPDATE files SET is_user_deleted = 1 WHERE id = ?', ['gone']);

      // Exactly what a force sync does: re-upsert the row as the source sees
      // it, with is_user_deleted false because no scanner knows about it.
      await repo.upsertAll([photo('gone')]);

      final rows = await db.select(
        'SELECT is_user_deleted, is_deleted FROM files WHERE id = ?', ['gone']);
      expect(rows.first['is_user_deleted'], 1,
          reason: 'the scanner must not resurrect a user delete');
      expect(rows.first['is_deleted'], 0,
          reason: 'is_deleted is still the scanner\'s to reset');
      expect((await PhotosRepository().photos()).map((f) => f.id),
          isNot(contains('gone')));
    });

    test('hiding and deleting stay independent', () async {
      final repo = FileDesktopRepository(db);
      await repo.create(photo('hidden'));
      await db.execute(
        'UPDATE files SET is_hidden = 1 WHERE id = ?', ['hidden']);
      await repo.upsertAll([photo('hidden')]);

      final rows = await db.select(
        'SELECT is_hidden, is_user_deleted FROM files WHERE id = ?', ['hidden']);
      expect(rows.first['is_hidden'], 1, reason: 'hide also survives a sync');
      expect(rows.first['is_user_deleted'], 0);
    });

    test('the delete path can still read rows it has marked', () async {
      final repo = FileDesktopRepository(db);
      await repo.create(photo('gone'));
      await db.execute(
        'UPDATE files SET is_user_deleted = 1 WHERE id = ?', ['gone']);

      // filesByIds deliberately ignores the flag: deleteSelectedFiles marks the
      // rows first, then needs them back to reach their sources.
      final found = await PhotosRepository().filesByIds({'gone'});
      expect(found.map((f) => f.id), ['gone']);
    });
  });
}
