import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

/// A collection whose policy says "don't index" must be invisible to every
/// embedding queue; a collection with no policy keeps today's behaviour.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tempDir;
  late DatabaseManager dm;
  late AppDatabase db;

  setUp(() async {
    tempDir = await io.Directory.systemTemp.createTemp('mds_policy_idx_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);
    dm = DatabaseManager.instance;
    await dm.initializeDatabase();
    db = dm.database!;
  });

  tearDown(() async {
    dm.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> addCollectionWithImage(String id, String? policy) async {
    await CollectionRepository(db).addCollection(
      Collection(
        id: id,
        name: id,
        path: '/$id',
        type: 'file',
        scanner: 'local',
        needsReAuth: false,
        scanStatus: 'idle',
        contentPolicy: policy,
      ),
    );
    await FileDesktopRepository(db).create(
      File(
        id: 'f-$id',
        name: 'a.jpg',
        path: '/$id/a.jpg',
        parent: '/$id',
        dateCreated: DateTime(2026),
        dateLastModified: DateTime(2026),
        collectionId: id,
        contentType: 'image/jpeg',
        size: 1,
        isDeleted: false,
      ),
    );
  }

  test('content_policy round-trips through the repository', () async {
    await addCollectionWithImage('c1', ContentPolicy.everything.encode());
    final c = await CollectionRepository(db).collectionById('c1');
    expect(c!.contentPolicy, ContentPolicy.everything.encode());
  });

  test(
    'non-indexing collections are left out of the embedding queue',
    () async {
      await addCollectionWithImage('legacy', null);
      await addCollectionWithImage(
        'indexed',
        const ContentPolicy(downloadCategories: {}).encode(),
      );
      await addCollectionWithImage(
        'skipped',
        const ContentPolicy(downloadCategories: {}, index: false).encode(),
      );
      final files =
          await DatabaseRepository(db).getFilesWithMissingEmbeddings();
      expect(
        files.map((f) => f.id),
        unorderedEquals(['f-legacy', 'f-indexed']),
      );
    },
  );
}
