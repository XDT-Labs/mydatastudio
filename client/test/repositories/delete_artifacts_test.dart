import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/main.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/search/services/email_contact_repository.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/modules/files/services/utilities/thumbnail_cache.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_model.dart';

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
        List<double>.filled(EmbeddingModel.dimension, 0.5),
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
      await DatabaseRepository(db).replaceEmailEmbeddings(emailId, [
        List<double>.filled(EmbeddingModel.dimension, 0.25),
      ]);

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
      await DatabaseRepository(db).replaceEmailEmbeddings(emailId, [
        List<double>.filled(EmbeddingModel.dimension, 0.75),
      ]);

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
        List<double>.filled(EmbeddingModel.dimension, 0.9),
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

  group('Deleted collection cleanup', () {
    late io.Directory tempDir;
    late DatabaseManager manager;
    late AppDatabase db;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_del_pending_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => tempDir.path);
      manager = DatabaseManager.instance;
      await manager.initializeDatabase();
      db = manager.database!;
    });

    tearDown(() async {
      manager.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Collection> emailCollection(String id) async {
      final col = Collection(
        id: id,
        name: id,
        path: '',
        type: 'email',
        scanner: 'email.imap',
        scanStatus: 'idle',
        needsReAuth: false,
      );
      await CollectionRepository(db).addCollection(col);
      return col;
    }

    test('a database created before the retry table can delete a collection', () async {
      // schemaDDL only runs when a database is first created, so a table
      // declared there alone is missing from every existing archive, and
      // deleting a collection throws.
      final col = await emailCollection('c-upgraded');
      await db.execute('DROP TABLE pending_disk_deletes');

      await db.initSchema();
      await CollectionRepository(db).deleteCollection(col.id);

      expect(
        await db.select('SELECT id FROM collections WHERE id = ?', [col.id]),
        isEmpty,
      );
    });

    test('a sync folder takes its archive copies, never the folder itself', () async {
      // The archive is the app's own copy, under the storage root; the synced
      // folder belongs to the user and the sync app.
      final root = MainApp.appDataDirectory.value!;
      final synced = io.Directory(p.join(tempDir.path, 'Dropbox'))
        ..createSync(recursive: true);
      io.File(p.join(synced.path, 'keep.txt')).writeAsStringSync('mine');
      final col = Collection(
        id: 'c-sync',
        name: 'Dropbox',
        path: synced.path,
        localCopyPath: synced.path,
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
        scanStatus: 'idle',
        needsReAuth: false,
      );
      await CollectionRepository(db).addCollection(col);
      final archive = io.Directory(p.join(root, 'files', 'sync', col.id))
        ..createSync(recursive: true);
      io.File(p.join(archive.path, 'keep.txt')).writeAsStringSync('copy');

      await CollectionRepository(db).deleteCollection(col.id);

      expect(archive.existsSync(), isFalse);
      expect(io.File(p.join(synced.path, 'keep.txt')).existsSync(), isTrue);
    });

    test('attachments survive unreachable storage and go on the next run', () async {
      // The rows are gone by the time disk cleanup runs. Without a retry, one
      // failure leaves the mail's bytes on disk with nothing pointing at them.
      final col = await emailCollection('c-pending');
      final root = MainApp.appDataDirectory.value!;
      final dir = io.Directory(p.join(root, 'files', 'email', col.id))
        ..createSync(recursive: true);

      MainApp.appDataDirectory.add(null);
      await CollectionRepository(db).deleteCollection(col.id);
      expect(dir.existsSync(), isTrue);
      expect(await db.select('SELECT * FROM pending_disk_deletes'), isNotEmpty);

      MainApp.appDataDirectory.add(root);
      await CollectionRepository(db).deletePendingDiskPaths();
      expect(dir.existsSync(), isFalse);
      expect(await db.select('SELECT * FROM pending_disk_deletes'), isEmpty);
    });

    test('deleting an account removes addresses only it had seen', () async {
      // They feed search suggestions, so they'd outlive the deleted account.
      await emailCollection('c-gone');
      await emailCollection('c-kept');
      Email mail(String id, String col, String from) => Email(
        id: id,
        collectionId: col,
        date: DateTime(2026),
        from: from,
        to: const ['shared@example.com'],
        subject: 's',
        isDeleted: false,
      );
      final emails = [
        mail('e1', 'c-gone', 'only-gone@example.com'),
        mail('e2', 'c-kept', 'kept@example.com'),
      ];
      await EmailRepository(db).addEmails(emails);
      await EmailContactRepository(db).indexEmails(emails);

      await CollectionRepository(db).deleteCollection('c-gone');

      final rows = await db.select(
        'SELECT address, message_count FROM emails_contacts ORDER BY address',
      );
      expect(rows.map((r) => r['address']), [
        'kept@example.com',
        'shared@example.com',
      ]);
      expect(rows.last['message_count'], 1);
    });

    test('deleting emails takes them out of the contacts index', () async {
      await emailCollection('c-mail');
      Email mail(String id, String from) => Email(
        id: id,
        collectionId: 'c-mail',
        date: DateTime(2026),
        from: from,
        to: const ['me@example.com'],
        subject: 's',
        isDeleted: false,
      );
      final emails = [mail('a', 'one@example.com'), mail('b', 'two@example.com')];
      await EmailRepository(db).addEmails(emails);
      await EmailContactRepository(db).indexEmails(emails);

      await EmailRepository(db).deleteEmails(['a']);

      final rows = await db.select(
        'SELECT address, message_count FROM emails_contacts ORDER BY address',
      );
      expect(rows.map((r) => r['address']), [
        'me@example.com',
        'two@example.com',
      ]);
      expect(rows.first['message_count'], 1);
    });
  });
}
