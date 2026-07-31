import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

/// Thumbnails are generated off to the side of the scan. The scanner enqueues a
/// background job the moment it sees an image and moves on; the job writes the
/// cache key with its own `UPDATE files SET thumbnail = ?` whenever it finishes.
/// The row it targets, meanwhile, doesn't reach the database until the
/// surrounding 100-file batch flushes, and every file in that batch carries
/// `thumbnail: null` because generation hadn't happened when the batch was
/// built.
///
/// So the two writes race, and the batch is just as likely to arrive second. If
/// the upsert overwrote the column unconditionally it would erase a key that
/// was already correct — the thumbnail sits on disk, the DB says there isn't
/// one, and the UI renders a broken-image placeholder forever. Nothing errors
/// and the next scan sees an unchanged mtime, so it never regenerates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('upsertAll thumbnail handling', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late FileDesktopRepository repo;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_thumb_');

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
      repo = FileDesktopRepository(db);
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    File imageRow({String? thumbnail}) => File(
      id: 'col-1:photo.jpg',
      name: 'photo.jpg',
      path: 'photo.jpg',
      parent: '',
      dateCreated: DateTime.now(),
      dateLastModified: DateTime.now(),
      lastScannedDate: DateTime.now(),
      collectionId: 'col-1',
      contentType: 'application/image',
      size: 3,
      isDeleted: false,
      thumbnail: thumbnail,
    );

    Future<String?> storedThumbnail() async {
      final rows = await db.select(
        'SELECT thumbnail FROM files WHERE id = ?',
        ['col-1:photo.jpg'],
      );
      return rows.single['thumbnail'] as String?;
    }

    test('a batch carrying null does not erase a key the job already wrote',
        () async {
      await repo.upsertAll([imageRow()]);

      // The background thumbnail job lands.
      const key = 'col-1/2c/2c65e8679a0e1c0a87d7a42c6714b65e150b2857.jpg';
      await db.execute('UPDATE files SET thumbnail = ? WHERE id = ?', [
        key,
        'col-1:photo.jpg',
      ]);

      // A later batch re-upserts the same file, still carrying null.
      await repo.upsertAll([imageRow()]);

      expect(await storedThumbnail(), key);
    });

    test('a batch carrying a thumbnail still overwrites the old one', () async {
      await repo.upsertAll([imageRow(thumbnail: 'http://old.example/thumb')]);
      await repo.upsertAll([imageRow(thumbnail: 'http://new.example/thumb')]);

      expect(await storedThumbnail(), 'http://new.example/thumb');
    });
  });
}
