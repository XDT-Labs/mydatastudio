import 'dart:io' as io;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';

/// The IMAP scanner stores each attachment's path relative to the collection's
/// extraction folder (`collections.local_copy_path`), while the PST importer
/// stores absolute paths. The email view reads attachment bytes straight from
/// `file.path` — to inline `cid:` images, draw thumbnails, and open or save the
/// file — so a relative path there resolves against the app's working
/// directory, finds nothing, and every embedded image renders broken.
/// `getAttachments` is the one place the view gets attachments from, so it has
/// to hand back paths that exist on disk for both kinds of collection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EmailRepository.getAttachments returns paths that exist on disk', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_att_');
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

    Future<void> insertCollection(String id, String? localCopyPath) =>
        db.execute(
          'INSERT INTO collections (id, name, path, type, scanner, scan_status, '
          'local_copy_path) VALUES (?, ?, ?, ?, ?, ?, ?)',
          [id, 'Mail', '', 'email', 'email.imap', 'idle', localCopyPath],
        );

    Future<void> insertAttachment({
      required String id,
      required String collectionId,
      required String path,
    }) => db.execute(
      'INSERT INTO files (id, collection_id, name, path, parent, content_type, '
      'size, is_deleted, email_id, date_created, date_last_modified) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)',
      [
        id,
        collectionId,
        'logo.png',
        path,
        '',
        'image',
        4,
        'msg-1',
        1700000000000,
        1700000000000,
      ],
    );

    test('an IMAP attachment stored relative to the extraction folder '
        'comes back as an absolute path to the extracted file', () async {
      final root = p.join(tempDir.path, 'files', 'email', 'col-imap');
      final relative = p.join('INBOX', '2026', 'logo.png');
      final onDisk = io.File(p.join(root, relative));
      await onDisk.create(recursive: true);
      await onDisk.writeAsBytes([1, 2, 3, 4]);

      await insertCollection('col-imap', root);
      await insertAttachment(
        id: 'att-imap',
        collectionId: 'col-imap',
        path: relative,
      );

      final attachments = await EmailRepository(db).getAttachments('msg-1');

      expect(attachments, hasLength(1));
      expect(attachments.single.path, onDisk.path);
      expect(await io.File(attachments.single.path).exists(), isTrue);
    });

    test('a PST attachment already stored as an absolute path is returned '
        'unchanged', () async {
      final absolute = p.join(tempDir.path, 'pst', 'logo.png');

      await insertCollection('col-pst', p.join(tempDir.path, 'elsewhere'));
      await insertAttachment(
        id: 'att-pst',
        collectionId: 'col-pst',
        path: absolute,
      );

      final attachments = await EmailRepository(db).getAttachments('msg-1');

      expect(attachments.single.path, absolute);
    });
  });
}
