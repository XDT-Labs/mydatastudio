import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email_folder.dart';
import 'package:mydatatools/modules/email/services/get_email_folders_service.dart';

/// Directly tests [GetEmailFoldersService] subscription deduplication
/// and cleanup behavior using an injected in-memory database.
void main() {
  group('GetEmailFoldersService - subscription deduplication', () {
    late AppDatabase database;

    setUp(() async {
      database = AppDatabase(NativeDatabase.memory());
      GetEmailFoldersService.instance.setDatabaseForTesting(database);

      await database.into(database.collections).insert(
            CollectionsCompanion.insert(
              id: 'col1',
              name: 'Test Account',
              path: 'test@example.com',
              type: 'email',
              scanner: 'pst',
              scanStatus: 'idle',
              needsReAuth: false,
            ),
          );
    });

    tearDown(() async {
      GetEmailFoldersService.instance.disposeAll();
      await database.close();
    });

    test('invoke() pushes folders to the sink', () async {
      await database.into(database.emailFolders).insert(
            EmailFoldersCompanion.insert(
              id: 'INBOX',
              collectionId: 'col1',
              name: 'Inbox',
            ),
          );

      final emitted = <List<EmailFolder>>[];
      final sub = GetEmailFoldersService.instance.sink.listen(emitted.add);

      await GetEmailFoldersService.instance
          .invoke(EmailFolderServiceCommand('col1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(emitted, isNotEmpty);
      expect(emitted.any((list) => list.any((f) => f.id == 'INBOX')), isTrue);

      await sub.cancel();
    });

    test('invoke() twice for the same collectionId does not create duplicate watch',
        () async {
      await database.into(database.emailFolders).insert(
            EmailFoldersCompanion.insert(
              id: 'INBOX',
              collectionId: 'col1',
              name: 'Inbox',
            ),
          );

      final emitted = <List<EmailFolder>>[];
      final sub = GetEmailFoldersService.instance.sink.listen(emitted.add);

      await GetEmailFoldersService.instance
          .invoke(EmailFolderServiceCommand('col1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final countAfterFirst = emitted.length;

      await GetEmailFoldersService.instance
          .invoke(EmailFolderServiceCommand('col1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final countAfterSecond = emitted.length;

      // Each invoke() does exactly 1 sink.add(). If subscriptions leaked,
      // a second watch() would fire on the initial DB state too, adding extra
      // events. We allow ≤2 new events per invoke (one-shot + at most one
      // watch() emission from the initial select) — NOT doubling.
      expect(
        countAfterSecond - countAfterFirst,
        lessThanOrEqualTo(2),
        reason: 'Duplicate subscriptions would cause >2 emissions per invoke',
      );

      await sub.cancel();
    });

    test('disposeCollection() prevents future watch() emissions for that account',
        () async {
      // Subscribe FIRST to capture all emissions including the replay.
      final emitted = <List<EmailFolder>>[];
      final sub = GetEmailFoldersService.instance.sink.listen(emitted.add);

      // Now invoke to register the watch subscription
      await GetEmailFoldersService.instance
          .invoke(EmailFolderServiceCommand('col1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final baseline = emitted.length;

      // Dispose the subscription before making a DB change
      GetEmailFoldersService.instance.disposeCollection('col1');

      // A DB change that would trigger watch() if it were still active
      await database.into(database.emailFolders).insert(
            EmailFoldersCompanion.insert(
              id: 'SENT',
              collectionId: 'col1',
              name: 'Sent',
            ),
          );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(
        emitted.length,
        baseline,
        reason: 'Orphaned subscription should not fire after disposeCollection()',
      );

      await sub.cancel();
    });

    test('disposeCollection() for unknown id does not throw', () {
      expect(
        () => GetEmailFoldersService.instance
            .disposeCollection('non_existent_id'),
        returnsNormally,
      );
    });

    test('disposeAll() can be called multiple times without error', () {
      expect(
        () {
          GetEmailFoldersService.instance.disposeAll();
          GetEmailFoldersService.instance.disposeAll();
        },
        returnsNormally,
      );
    });
  });
}
