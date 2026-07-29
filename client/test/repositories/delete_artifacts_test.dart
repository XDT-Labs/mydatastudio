import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';

/// Deletion has to take every artifact with it, or the archive accumulates
/// ghosts: cached thumbnails for files that are gone, attachment bytes with no
/// row pointing at them, and embedding vectors for content that no longer
/// exists — which nothing reclaims, since the "missing embeddings" queues only
/// walk live rows.
///
/// The embedding rows are covered by `ON DELETE CASCADE` (resqlite enables
/// `PRAGMA foreign_keys` on every connection) and asserted here so that stays
/// true. Everything on disk is the delete path's own responsibility, enforced
/// by nothing, and a regression there is completely silent — no error, no
/// broken row, just bytes that never go away.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Deletion leaves no artifacts behind', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();

      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_del_');

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
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    /// A collection whose files live under [root], mirroring how the scanners
    /// store them: the row's path is relative to the collection root.
    Future<Collection> makeCollection(String type, String root) async {
      final col = Collection(
        id: const Uuid().v4(),
        name: 'Test $type',
        path: root,
        type: type,
        scanner: type == 'email' ? 'yahoo' : 'local',
        needsReAuth: false,
        scanStatus: 'idle',
        localCopyPath: root,
      );
      await CollectionRepository(db).addCollection(col);
      return col;
    }

    /// Writes real bytes and a real cached thumbnail for a file row, returning
    /// the row plus the two on-disk paths it now owns.
    Future<(File, io.File, io.File)> makeFileWithArtifacts(
      Collection col,
      String relPath, {
      String? emailId,
      bool isDeleted = false,
    }) async {
      final id = const Uuid().v4();

      final onDisk = io.File(p.join(col.path, relPath));
      await onDisk.parent.create(recursive: true);
      await onDisk.writeAsBytes([1, 2, 3]);

      final cache = ThumbnailCache(tempDir.path);
      final key = cache.keyFor(col.id, id);
      await cache.writeBytes(key, [4, 5, 6]);

      final file = File(
        id: id,
        name: p.basename(relPath),
        path: relPath,
        parent: p.dirname(relPath),
        dateCreated: DateTime.now(),
        dateLastModified: DateTime.now(),
        collectionId: col.id,
        contentType: 'image/jpeg',
        size: 3,
        isDeleted: isDeleted,
        thumbnail: key,
        emailId: emailId,
      );
      await FileDesktopRepository(db).create(file);
      await DatabaseRepository(db).upsertFileEmbedding(
        id,
        List<double>.filled(2048, 0.5),
      );

      return (file, onDisk, cache.fileForKey(key));
    }

    Future<int> countWhere(String sql, List<Object?> args) async {
      final rows = await db.select(sql, args);
      return rows.length;
    }

    test('a delete larger than one parameter batch still clears', () async {
      // SQLite caps a statement at 32766 bound parameters, so an id list
      // expanded into `IN (?, ?, …)` cannot be unbounded — a folder resync
      // that finds tens of thousands of messages gone hands exactly that to
      // one delete. Crossing the batch boundary is what this asserts; the
      // ceiling itself is too large to reach in a test cheaply.
      final col = await makeCollection('file', p.join(tempDir.path, 'bulk'));
      final files = <File>[];
      for (var i = 0; i < 1201; i++) {
        final file = File(
          id: 'bulk-$i',
          name: 'f$i.jpg',
          path: 'f$i.jpg',
          parent: '',
          dateCreated: DateTime.now(),
          dateLastModified: DateTime.now(),
          collectionId: col.id,
          contentType: 'image/jpeg',
          size: 1,
          isDeleted: false,
        );
        await FileDesktopRepository(db).create(file);
        files.add(file);
      }

      await FileDesktopRepository(db).deleteFiles(files, collection: col);

      expect(
        await countWhere('SELECT 1 FROM files WHERE collection_id = ?', [
          col.id,
        ]),
        0,
        reason: 'every batch must be applied, not just the first',
      );
    });

    test('deleting a file takes its embedding, thumbnail and bytes', () async {
      final col = await makeCollection('file', p.join(tempDir.path, 'photos'));
      final (file, onDisk, thumb) = await makeFileWithArtifacts(
        col,
        'holiday/beach.jpg',
      );

      // Precondition: all four artifacts exist.
      expect(await onDisk.exists(), isTrue);
      expect(await thumb.exists(), isTrue);
      expect(
        await countWhere(
          'SELECT 1 FROM files_embeddings WHERE file_id = ?',
          [file.id],
        ),
        1,
      );

      await FileDesktopRepository(db).delete(file, collection: col);

      expect(
        await countWhere('SELECT 1 FROM files WHERE id = ?', [file.id]),
        0,
        reason: 'row must be gone',
      );
      expect(
        await countWhere(
          'SELECT 1 FROM files_embeddings WHERE file_id = ?',
          [file.id],
        ),
        0,
        reason: 'cascade must reach the vector index',
      );
      expect(await thumb.exists(), isFalse, reason: 'cached thumbnail leaked');
      expect(
        await onDisk.exists(),
        isFalse,
        reason:
            'the row stores a path relative to the collection root, so an '
            'unresolved unlink silently misses the bytes',
      );
    });

    test('deleting mail takes its attachments and both embeddings', () async {
      final root = p.join(tempDir.path, 'files', 'email');
      final col = await makeCollection('email', root);

      final emailId = const Uuid().v4();
      await db.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        'is_deleted) VALUES (?, ?, ?, ?, ?, ?, 0)',
        [
          emailId,
          col.id,
          DateTime.now().millisecondsSinceEpoch,
          'sender@example.com',
          'me@example.com',
          'With attachments',
        ],
      );
      await DatabaseRepository(db).upsertEmailEmbedding(
        emailId,
        List<double>.filled(2048, 0.25),
      );

      final (attachment, attachmentBytes, attachmentThumb) =
          await makeFileWithArtifacts(
            col,
            'INBOX/2024/photo.jpg',
            emailId: emailId,
          );
      // A previous scan sweep soft-deleted this one. It is the row most likely
      // to be stranded, because the attachment lookup used to skip it.
      final (stale, staleBytes, staleThumb) = await makeFileWithArtifacts(
        col,
        'INBOX/2024/old.jpg',
        emailId: emailId,
        isDeleted: true,
      );

      await EmailRepository(db).deleteEmails([emailId], collection: col);

      expect(
        await countWhere('SELECT 1 FROM emails WHERE id = ?', [emailId]),
        0,
      );
      expect(
        await countWhere(
          'SELECT 1 FROM emails_embeddings WHERE email_id = ?',
          [emailId],
        ),
        0,
        reason: 'cascade must reach the mail vector index',
      );
      expect(
        await countWhere(
          'SELECT 1 FROM files WHERE email_id = ?',
          [emailId],
        ),
        0,
        reason: 'including the soft-deleted attachment',
      );
      for (final id in [attachment.id, stale.id]) {
        expect(
          await countWhere(
            'SELECT 1 FROM files_embeddings WHERE file_id = ?',
            [id],
          ),
          0,
        );
      }
      expect(await attachmentBytes.exists(), isFalse);
      expect(await staleBytes.exists(), isFalse);
      expect(await attachmentThumb.exists(), isFalse);
      expect(await staleThumb.exists(), isFalse);
    });

    test('deleting a collection takes every row and thumbnail', () async {
      final col = await makeCollection('file', p.join(tempDir.path, 'archive'));
      final (file, _, thumb) = await makeFileWithArtifacts(col, 'a/one.jpg');

      final emailId = const Uuid().v4();
      await db.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        'is_deleted) VALUES (?, ?, ?, ?, ?, ?, 0)',
        [
          emailId,
          col.id,
          DateTime.now().millisecondsSinceEpoch,
          'sender@example.com',
          'me@example.com',
          'Subject',
        ],
      );
      await DatabaseRepository(db).upsertEmailEmbedding(
        emailId,
        List<double>.filled(2048, 0.75),
      );

      await CollectionRepository(db).deleteCollection(col.id);

      for (final check in [
        ('collections', 'SELECT 1 FROM collections WHERE id = ?', col.id),
        ('files', 'SELECT 1 FROM files WHERE collection_id = ?', col.id),
        ('folders', 'SELECT 1 FROM folders WHERE collection_id = ?', col.id),
        ('emails', 'SELECT 1 FROM emails WHERE collection_id = ?', col.id),
        (
          'files_embeddings',
          'SELECT 1 FROM files_embeddings WHERE file_id = ?',
          file.id,
        ),
        (
          'emails_embeddings',
          'SELECT 1 FROM emails_embeddings WHERE email_id = ?',
          emailId,
        ),
      ]) {
        final (table, sql, arg) = check;
        expect(await countWhere(sql, [arg]), 0, reason: '$table not cleared');
      }
      expect(await thumb.exists(), isFalse);
      expect(
        await io.Directory(p.join(tempDir.path, 'thumbnails', col.id)).exists(),
        isFalse,
      );
    });

    test('an embedding written after the row is gone is dropped', () async {
      // The embedding isolates run independently of deletion, so a file can be
      // deleted while its embedding is mid-flight. Without the guard that
      // write hits a foreign key that no longer resolves and throws mid-scan.
      // A vanished file is a no-op, not a failure.
      final col = await makeCollection('file', p.join(tempDir.path, 'race'));
      final (file, _, _) = await makeFileWithArtifacts(col, 'race.jpg');

      await FileDesktopRepository(db).delete(file, collection: col);
      await DatabaseRepository(db).upsertFileEmbedding(
        file.id,
        List<double>.filled(2048, 0.9),
      );

      expect(
        await countWhere(
          'SELECT 1 FROM files_embeddings WHERE file_id = ?',
          [file.id],
        ),
        0,
      );
    });

    test('startup reaps orphans left by earlier versions', () async {
      final col = await makeCollection('file', p.join(tempDir.path, 'legacy'));
      final (file, _, thumb) = await makeFileWithArtifacts(col, 'legacy.jpg');

      // Simulate what the old delete paths left behind: the row gone, the
      // thumbnail still on disk. (The embedding goes with the row here — an
      // install old enough to have orphaned those predates foreign keys being
      // enabled, which this harness can't reproduce.)
      await db.execute('DELETE FROM files WHERE id = ?', [file.id]);
      expect(await thumb.exists(), isTrue);

      // The reap is a one-time migration, so rewind the marker the way an
      // install that predates it would look.
      await db.execute('PRAGMA user_version = 0');
      await db.initSchema();

      expect(
        await countWhere(
          'SELECT 1 FROM files_embeddings WHERE file_id = ?',
          [file.id],
        ),
        0,
      );
      expect(await thumb.exists(), isFalse);
    });
  });
}
