import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';

/// The settings dialog holds a possibly stale Collection; saving the policy
/// must not rewrite the row (it would clobber tokens a scanner just refreshed).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CollectionRepository.updateEmailDeletePolicy', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late CollectionRepository repo;
    late String id;

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mds_deletepolicy_');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      // ignore: deprecated_member_use
      channel.setMockMethodCallHandler((MethodCall call) async => tempDir.path);
      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
      repo = CollectionRepository(db);
      id = const Uuid().v4();
      await repo.addCollection(
        Collection(
          id: id,
          name: 'Work',
          path: '',
          type: 'email',
          scanner: 'email.imap',
          needsReAuth: false,
          scanStatus: 'idle',
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

    test('defaults to keep and persists the new policy', () async {
      expect((await repo.collectionById(id))!.emailDeletePolicy,
          EmailDeletePolicy.keep);
      await repo.updateEmailDeletePolicy(id, EmailDeletePolicy.markDeleted);
      expect((await repo.collectionById(id))!.emailDeletePolicy,
          EmailDeletePolicy.markDeleted);
    });

    test('changes only that column, leaving a refreshed token intact', () async {
      // A scanner writes a token after the dialog loaded its (token-less) Collection.
      await db.execute(
          'UPDATE collections SET access_token = ?, scan_status = ? WHERE id = ?',
          ['fresh-token', 'scanning', id]);

      await repo.updateEmailDeletePolicy(id, EmailDeletePolicy.remove);

      final row = (await db.select(
              'SELECT access_token, scan_status, name, email_delete_policy '
              'FROM collections WHERE id = ?',
              [id]))
          .single;
      expect(row['email_delete_policy'], 'remove');
      expect(row['access_token'], equals('fresh-token'));
      expect(row['scan_status'], 'scanning');
      expect(row['name'], 'Work');
    });
  });
}
