import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// What a source-side delete does to our rows. keep_deleted_files exists so a
/// user who archives a drive keeps files the source later loses; if the
/// removal path ignored it, the archive would silently shrink.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tempDir;
  late DatabaseManager manager;
  late AppDatabase db;
  late FileDesktopRepository repo;

  setUp(() async {
    tempDir = await io.Directory.systemTemp.createTemp('mds_cloudrm_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);
    manager = DatabaseManager.instance;
    await manager.initializeDatabase();
    db = manager.database!;
    await CollectionRepository(db).addCollection(
      Collection(
        id: 'c1',
        name: 'Drive',
        path: 'root',
        type: 'file',
        scanner: 'gdrive',
        needsReAuth: false,
        scanStatus: 'idle',
      ),
    );
    repo = FileDesktopRepository(db);
    await repo.upsertAll([_file('a', parent: ''), _file('b', parent: 'dir')]);
  });

  tearDown(() async {
    manager.dispose();
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, dynamic>> row(String id) async =>
      (await db.select('SELECT * FROM files WHERE id = ?', [id])).single;

  test('removal marks is_deleted when deleted files are not kept', () async {
    await repo.applyCloudRemovals(
      'c1',
      itemIds: ['c1:a'],
      parentIds: ['dir'],
      keepDeleted: false,
      at: DateTime(2026, 5, 1),
    );
    expect((await row('c1:a'))['is_deleted'], 1);
    expect((await row('c1:b'))['is_deleted'], 1, reason: 'matched by parent');
    expect((await row('c1:a'))['source_deleted_date'], isNull);
  });

  test('removal with keepDeleted stamps source_deleted_date only', () async {
    final at = DateTime(2026, 5, 1);
    await repo.applyCloudRemovals(
      'c1',
      itemIds: ['c1:a'],
      parentIds: [],
      keepDeleted: true,
      at: at,
    );
    final r = await row('c1:a');
    expect(r['is_deleted'], 0);
    expect(r['source_deleted_date'], at.millisecondsSinceEpoch);
  });

  test(
    'keepDeleted keeps the folder row so kept files stay browsable',
    () async {
      await db.execute(
        "INSERT INTO folders (id, name, path, parent, collection_id) "
        "VALUES ('c1:dir', 'dir', 'dir', '', 'c1')",
      );
      await repo.applyCloudRemovals(
        'c1',
        itemIds: ['c1:dir'],
        parentIds: ['dir'],
        keepDeleted: true,
        at: DateTime(2026, 5, 1),
      );
      expect(
        await db.select("SELECT id FROM folders WHERE id = 'c1:dir'"),
        hasLength(1),
      );
      final r = await row('c1:b');
      expect(r['is_deleted'], 0);
      expect(r['source_deleted_date'], isNotNull);
    },
  );

  test('without keepDeleted the folder row is removed', () async {
    await db.execute(
      "INSERT INTO folders (id, name, path, parent, collection_id) "
      "VALUES ('c1:dir', 'dir', 'dir', '', 'c1')",
    );
    await repo.applyCloudRemovals(
      'c1',
      itemIds: ['c1:dir'],
      parentIds: ['dir'],
      keepDeleted: false,
      at: DateTime(2026, 5, 1),
    );
    expect(
      await db.select("SELECT id FROM folders WHERE id = 'c1:dir'"),
      isEmpty,
    );
  });

  test('handles id lists larger than one statement can bind', () async {
    final ids = [for (var i = 0; i < 1200; i++) 'c1:x$i'];
    await repo.upsertAll([
      for (var i = 0; i < 1200; i++) _file('x$i', parent: 'big'),
    ]);
    await repo.applyCloudRemovals(
      'c1',
      itemIds: ids,
      parentIds: [for (var i = 0; i < 1200; i++) 'nope$i'],
      keepDeleted: false,
      at: DateTime(2026, 5, 1),
      chunkSize: 500,
    );
    final n = await db.select(
      "SELECT count(*) AS n FROM files WHERE is_deleted = 1 AND id LIKE 'c1:x%'",
    );
    expect(n.single['n'], 1200);
    expect((await row('c1:a'))['is_deleted'], 0);
  });

  test(
    'a file that reappears at the source clears source_deleted_date',
    () async {
      await repo.applyCloudRemovals(
        'c1',
        itemIds: ['c1:a'],
        parentIds: [],
        keepDeleted: true,
        at: DateTime(2026, 5, 1),
      );
      await repo.upsertAll([_file('a', parent: '')]);
      expect((await row('c1:a'))['source_deleted_date'], isNull);
    },
  );

  test('sweep with keepDeleted stamps instead of hiding', () async {
    await repo.markMissingAsDeleted(
      'c1',
      '',
      DateTime.now().add(const Duration(minutes: 1)),
      isCloud: true,
      isFullScan: true,
      keepDeleted: true,
    );
    final r = await row('c1:a');
    expect(r['is_deleted'], 0);
    expect(r['source_deleted_date'], isNotNull);
  });

  test('change_cursor round-trips and can be cleared', () async {
    final repoC = CollectionRepository(db);
    await repoC.setChangeCursor('c1', 'tok');
    expect((await repoC.collectionById('c1'))!.changeCursor, 'tok');
    await repoC.setChangeCursor('c1', null);
    expect((await repoC.collectionById('c1'))!.changeCursor, isNull);
  });
}

File _file(String id, {required String parent}) => File(
  id: 'c1:$id',
  name: '$id.txt',
  path: 'gdrive://$id',
  parent: parent,
  dateCreated: DateTime(2026, 1, 1),
  dateLastModified: DateTime(2026, 1, 1),
  collectionId: 'c1',
  contentType: 'text/plain',
  size: 1,
  isDeleted: false,
);
