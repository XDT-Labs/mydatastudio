import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// Opening a folder has to show everything its own count promises.
///
/// `email_folders.messages_total` is a recursive count — over a real Outlook
/// archive, summing it across the top-level folders reproduced the archive's
/// total message count exactly. A folder listing only its *direct* messages
/// therefore contradicted its own badge: that archive's Inbox advertised 1,318
/// messages and held none of its own, so opening it looked like the import had
/// silently failed. Flat mailboxes never showed it, which is why this hid
/// behind Gmail and Yahoo working fine.
void main() {
  late Directory tempDir;
  late DatabaseManager databaseManager;
  late EmailRepository emails;
  late EmailFolderRepository folders;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('email_subtree_test_');

    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
          return tempDir.path;
        });

    databaseManager = DatabaseManager.instance;
    await databaseManager.initializeDatabase();
    final db = databaseManager.database!;

    emails = EmailRepository(db);
    folders = EmailFolderRepository(db);

    final colRepo = CollectionRepository(db);
    for (final id in ['archive', 'other']) {
      await colRepo.addCollection(
        Collection(
          id: id,
          name: id,
          path: tempDir.path,
          type: 'email',
          scanner: 'email.outlook.pst',
          scanStatus: 'idle',
          needsReAuth: false,
        ),
      );
    }
  });

  tearDown(() async {
    databaseManager.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> addFolder(
    String id,
    String name, {
    String? parentId,
    String collectionId = 'archive',
  }) async {
    await folders.upsertFolder(
      EmailFolder(
        id: id,
        collectionId: collectionId,
        name: name,
        type: 'user',
        messagesTotal: 0,
        messagesUnread: 0,
        parentId: parentId,
      ),
    );
  }

  Future<void> addEmail(
    String id,
    String folderId, {
    String collectionId = 'archive',
  }) async {
    await emails.addEmails([
      Email(
        id: id,
        collectionId: collectionId,
        date: DateTime(2026, 5, 4),
        from: 'sender@example.com',
        to: const ['me@example.com'],
        subject: id,
        folderId: folderId,
        isDeleted: false,
      ),
    ]);
  }

  group('folder message listing', () {
    test('a parent folder lists messages held by its descendants', () async {
      // Inbox -> Allaire -> WebDev, the shape that broke: every message sits
      // at the bottom and the folder the user clicks holds none itself.
      await addFolder('inbox', 'Inbox');
      await addFolder('allaire', 'Allaire', parentId: 'inbox');
      await addFolder('webdev', '_WebDev', parentId: 'allaire');
      await addEmail('deep-1', 'webdev');
      await addEmail('mid-1', 'allaire');

      final result = await emails.emails('archive', folderId: 'inbox');

      expect(result.map((e) => e.id).toSet(), {'deep-1', 'mid-1'});
    });

    test('a folder still lists its own messages', () async {
      await addFolder('inbox', 'Inbox');
      await addFolder('allaire', 'Allaire', parentId: 'inbox');
      await addEmail('direct-1', 'inbox');
      await addEmail('deep-1', 'allaire');

      final result = await emails.emails('archive', folderId: 'inbox');

      expect(result.map((e) => e.id).toSet(), {'direct-1', 'deep-1'});
    });

    test('a leaf folder shows only itself, not its siblings', () async {
      // The subtree must widen a parent's view without widening a leaf's —
      // otherwise picking a specific folder stops meaning anything.
      await addFolder('inbox', 'Inbox');
      await addFolder('allaire', 'Allaire', parentId: 'inbox');
      await addFolder('humor', 'humor', parentId: 'inbox');
      await addEmail('in-allaire', 'allaire');
      await addEmail('in-humor', 'humor');

      final result = await emails.emails('archive', folderId: 'allaire');

      expect(result.map((e) => e.id).toSet(), {'in-allaire'});
    });

    test('a sibling folder is not swept in by the walk', () async {
      await addFolder('inbox', 'Inbox');
      await addFolder('sent', 'Sent Items');
      await addEmail('in-inbox', 'inbox');
      await addEmail('in-sent', 'sent');

      final result = await emails.emails('archive', folderId: 'inbox');

      expect(result.map((e) => e.id).toSet(), {'in-inbox'});
    });

    test('the walk does not cross into another collection', () async {
      // Folder ids are UUIDs, but the collection filter is what keeps a
      // second archive's identically-shaped tree out of this one's results.
      await addFolder('inbox', 'Inbox');
      await addFolder('child', 'Child', parentId: 'inbox');
      await addFolder(
        'other-child',
        'Child',
        parentId: 'inbox',
        collectionId: 'other',
      );
      await addEmail('mine', 'child');
      await addEmail('theirs', 'other-child', collectionId: 'other');

      final result = await emails.emails('archive', folderId: 'inbox');

      expect(result.map((e) => e.id).toSet(), {'mine'});
    });

    test('a parent cycle terminates instead of hanging', () async {
      // Nothing validates the parent chain an importer writes. Before the
      // depth bound this query would spin forever and take the UI with it.
      await addFolder('a', 'A', parentId: 'b');
      await addFolder('b', 'B', parentId: 'a');
      await addEmail('in-a', 'a');

      final result = await emails
          .emails('archive', folderId: 'a')
          .timeout(const Duration(seconds: 10));

      expect(result.map((e) => e.id), contains('in-a'));
    });
  });
}
