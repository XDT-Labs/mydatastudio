import 'dart:async';

import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/services/rx_service.dart';

class EmailFolderServiceCommand {
  final String collectionId;
  EmailFolderServiceCommand(this.collectionId);
}

/// A reactive service that loads email folders for a collection.
///
/// **Subscription management:** Each unique [collectionId] gets exactly one
/// persistent stream subscription. Calling [invoke] multiple times for the
/// same collectionId will NOT create duplicate subscriptions — it simply
/// returns the last-known value immediately via [sink]. Call
/// [disposeCollection] when an account is removed to clean up its subscription.
class GetEmailFoldersService
    extends RxService<EmailFolderServiceCommand, List<EmailFolder>> {
  static final GetEmailFoldersService instance =
      GetEmailFoldersService._internal();

  factory GetEmailFoldersService() {
    return instance;
  }

  /// Optional injected database for testing. When null the service uses the
  /// [DatabaseManager] singleton (production behaviour).
  AppDatabase? _db;

  GetEmailFoldersService._internal() : super();

  // @visibleForTesting: allow tests to inject a database without the singleton.
  void setDatabaseForTesting(AppDatabase db) {
    _db = db;
  }

  AppDatabase get _database => _db ?? DatabaseManager.instance.database!;

  /// Tracks one persistent watch subscription per collectionId.
  final Map<String, StreamSubscription<List<EmailFolder>>> _watchSubs = {};

  @override
  Future<List<EmailFolder>> invoke(EmailFolderServiceCommand command) async {
    final collectionId = command.collectionId;

    // Do a one-shot fetch immediately so callers get data right away.
    isLoading.add(true);
    final EmailFolderRepository repo = EmailFolderRepository(_database);
    final folders = await repo.byCollectionId(collectionId);
    sink.add(folders);
    isLoading.add(false);

    // Only set up the persistent stream if we don't already have one for
    // this collectionId. This prevents subscription leaks on repeated calls.
    if (!_watchSubs.containsKey(collectionId)) {
      final stream = _database
          .stream("SELECT * FROM email_folders WHERE collection_id = ?", [
            collectionId,
          ])
          .map((rows) {
            return rows.map((r) => EmailFolder.fromDbMap(r)).toList();
          });

      _watchSubs[collectionId] = stream.listen((updatedFolders) {
        sink.add(updatedFolders);
      });
    }

    return folders;
  }

  /// Cancel the reactive watch subscription for [collectionId]. Call this
  /// after deleting an account so the orphaned listener does not fire.
  void disposeCollection(String collectionId) {
    _watchSubs.remove(collectionId)?.cancel();
  }

  /// Cancel all active watch subscriptions (e.g. on app shutdown or test teardown).
  void disposeAll() {
    for (final sub in _watchSubs.values) {
      sub.cancel();
    }
    _watchSubs.clear();
    _db = null;
  }
}
