import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/sql_chunks.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/modules/email/services/email_folder_repository.dart';
import 'package:mydatastudio/modules/email/services/email_repository.dart';
import 'package:mydatastudio/repositories/collection_repository.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';

/// The writes of an incremental IMAP sync. They run on the main isolate's
/// connection (the scanner isolate only reads) and arrive through the
/// `emailSync` service of `handleScanWriteMessage`.
///
/// Folder membership: an email row has one primary `(folder_id, uid)`. The
/// same Message-ID found in further folders is *not* a second row; those
/// folders are added to `labels`, which the folder filter already honours.
class ImapSyncWriter {
  ImapSyncWriter(this.db);

  final AppDatabase db;

  /// Forgets everything about [folderId]'s UIDs: its sync state, and the UID
  /// of every email whose primary folder it is (they belong to a dead
  /// UIDVALIDITY and could collide with new, unrelated UIDs). Rows stay.
  Future<void> resetFolder(String collectionId, String folderId) async {
    await EmailFolderRepository(db).setSyncState(collectionId, folderId);
    await retryOnLock(
      () => db.execute(
        'UPDATE emails SET uid = NULL '
        'WHERE collection_id = ? AND folder_id = ? AND uid IS NOT NULL',
        [collectionId, folderId],
      ),
      label: 'ImapSyncWriter.resetFolder',
    );
  }

  Future<void> saveFolderState(
    String collectionId,
    String folderId, {
    int? uidValidity,
    int? uidNext,
    int? highestModseq,
    int? lastSyncedUid,
  }) => retryOnLock(
    () => EmailFolderRepository(db).setSyncState(
      collectionId,
      folderId,
      uidValidity: uidValidity,
      uidNext: uidNext,
      highestModseq: highestModseq,
      lastSyncedUid: lastSyncedUid,
    ),
    label: 'ImapSyncWriter.saveFolderState',
  );

  /// Points existing rows at their (new) UID in [folderId] and syncs the seen
  /// flag. Used when a re-fetch finds a message we already have.
  Future<void> rematch(
    String collectionId,
    String folderId,
    List<({String id, int uid, bool isRead})> rows,
  ) async {
    if (rows.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final r in rows) {
          await tx.execute(
            'UPDATE emails SET uid = ?, is_read = ? '
            'WHERE collection_id = ? AND id = ? AND folder_id = ?',
            [r.uid, r.isRead ? 1 : 0, collectionId, r.id, folderId],
          );
        }
      }),
      label: 'ImapSyncWriter.rematch',
    );
  }

  /// Records that [emailIds] (stored under another primary folder) are also in
  /// [folderId].
  Future<void> addMembership(
    String collectionId,
    String folderId,
    List<String> emailIds,
  ) async {
    if (emailIds.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final id in emailIds) {
          final rows = await tx.select(
            'SELECT folder_id, labels FROM emails '
            'WHERE collection_id = ? AND id = ?',
            [collectionId, id],
          );
          if (rows.isEmpty) continue;
          final primary = rows.first['folder_id'] as String?;
          if (primary == folderId) continue;
          final labels = _splitLabels(rows.first['labels'] as String?);
          if (labels.contains(folderId)) continue;
          labels.add(folderId);
          await tx.execute(
            'UPDATE emails SET labels = ? WHERE collection_id = ? AND id = ?',
            [labels.join(','), collectionId, id],
          );
        }
      }),
      label: 'ImapSyncWriter.addMembership',
    );
  }

  /// Applies server `\Seen` state to the primary copies in [folderId].
  Future<void> setRead(
    String collectionId,
    String folderId,
    Map<int, bool> readByUid,
  ) async {
    if (readByUid.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final e in readByUid.entries) {
          await tx.execute(
            'UPDATE emails SET is_read = ? '
            'WHERE collection_id = ? AND folder_id = ? AND uid = ?',
            [e.value ? 1 : 0, collectionId, folderId, e.key],
          );
        }
      }),
      label: 'ImapSyncWriter.setRead',
    );
  }

  /// Gmail: replaces the label memberships (and sets the thread) of the
  /// primary copies in [folderId] (All Mail) from X-GM-LABELS / X-GM-THRID.
  /// A null thread id leaves the stored one alone.
  Future<void> setGmailMeta(
    String collectionId,
    String folderId,
    List<({int uid, List<String> labels, String? threadId})> rows,
  ) async {
    if (rows.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final r in rows) {
          await tx.execute(
            'UPDATE emails SET labels = ?, thread_id = COALESCE(?, thread_id) '
            'WHERE collection_id = ? AND folder_id = ? AND uid = ?',
            [r.labels.join(','), r.threadId, collectionId, folderId, r.uid],
          );
        }
      }),
      label: 'ImapSyncWriter.setGmailMeta',
    );
  }

  /// Removes [folderId] from the labels of [emailIds]: the message is gone
  /// from that folder but lives on elsewhere.
  Future<void> dropMembership(
    String collectionId,
    String folderId,
    List<String> emailIds,
  ) async {
    if (emailIds.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final id in emailIds) {
          final rows = await tx.select(
            'SELECT labels FROM emails WHERE collection_id = ? AND id = ?',
            [collectionId, id],
          );
          if (rows.isEmpty) continue;
          final labels = _splitLabels(rows.first['labels'] as String?)
            ..remove(folderId);
          await tx.execute(
            'UPDATE emails SET labels = ? WHERE collection_id = ? AND id = ?',
            [labels.join(','), collectionId, id],
          );
        }
      }),
      label: 'ImapSyncWriter.dropMembership',
    );
  }

  /// A message vanished from its primary folder but another folder still has
  /// it: that copy becomes the primary. [labels] are the folders still left
  /// after the new primary is removed from the list.
  Future<void> promote(
    String collectionId,
    List<({String id, String folderId, int uid, List<String> labels})> moves,
  ) async {
    if (moves.isEmpty) return;
    await retryOnLock(
      () => db.transaction((tx) async {
        for (final m in moves) {
          await tx.execute(
            'UPDATE emails SET folder_id = ?, uid = ?, labels = ? '
            'WHERE collection_id = ? AND id = ?',
            [m.folderId, m.uid, m.labels.join(','), collectionId, m.id],
          );
        }
      }),
      label: 'ImapSyncWriter.promote',
    );
  }

  /// The messages are gone from the server everywhere: apply the account's
  /// [EmailDeletePolicy].
  ///   keep        - leave the rows exactly as they are.
  ///   markDeleted - hide them (`is_deleted = 1`).
  ///   remove      - delete the rows and their attachments.
  Future<void> applyDeletePolicy(
    Collection collection,
    List<String> emailIds,
  ) async {
    if (emailIds.isEmpty) return;
    switch (collection.emailDeletePolicy) {
      case EmailDeletePolicy.keep:
        return;
      case EmailDeletePolicy.markDeleted:
        await retryOnLock(
          () => db.transaction((tx) async {
            for (final chunk in sqlChunks(emailIds)) {
              final ph = List.filled(chunk.length, '?').join(',');
              await tx.execute(
                'UPDATE emails SET is_deleted = 1 '
                'WHERE collection_id = ? AND id IN ($ph)',
                [collection.id, ...chunk],
              );
            }
          }),
          label: 'ImapSyncWriter.markDeleted',
        );
      case EmailDeletePolicy.remove:
        await EmailRepository(
          db,
        ).deleteEmails(emailIds, collection: collection);
    }
  }

  /// Entry point for the `emailSync` relay service.
  static Future<void> handle(AppDatabase db, Map<dynamic, dynamic> p) async {
    final writer = ImapSyncWriter(db);
    final collectionId = p['collectionId'] as String;
    final folderId = p['folderId'] as String?;
    switch (p['op'] as String) {
      case 'resetFolder':
        await writer.resetFolder(collectionId, folderId!);
      case 'saveFolderState':
        await writer.saveFolderState(
          collectionId,
          folderId!,
          uidValidity: p['uidValidity'] as int?,
          uidNext: p['uidNext'] as int?,
          highestModseq: p['highestModseq'] as int?,
          lastSyncedUid: p['lastSyncedUid'] as int?,
        );
      case 'rematch':
        await writer.rematch(collectionId, folderId!, [
          for (final r in p['rows'] as List)
            (
              id: (r as Map)['id'] as String,
              uid: r['uid'] as int,
              isRead: r['isRead'] as bool,
            ),
        ]);
      case 'addMembership':
        await writer.addMembership(
          collectionId,
          folderId!,
          (p['ids'] as List).cast<String>(),
        );
      case 'dropMembership':
        await writer.dropMembership(
          collectionId,
          folderId!,
          (p['ids'] as List).cast<String>(),
        );
      case 'setRead':
        await writer.setRead(
          collectionId,
          folderId!,
          (p['readByUid'] as Map).cast<int, bool>(),
        );
      case 'setGmailMeta':
        await writer.setGmailMeta(collectionId, folderId!, [
          for (final r in p['rows'] as List)
            (
              uid: (r as Map)['uid'] as int,
              labels: (r['labels'] as List).cast<String>(),
              threadId: r['threadId'] as String?,
            ),
        ]);
      case 'promote':
        await writer.promote(collectionId, [
          for (final m in p['moves'] as List)
            (
              id: (m as Map)['id'] as String,
              folderId: m['folderId'] as String,
              uid: m['uid'] as int,
              labels: (m['labels'] as List).cast<String>(),
            ),
        ]);
      case 'applyDeletePolicy':
        final collection = await CollectionRepository(
          db,
        ).collectionById(collectionId);
        if (collection == null) return;
        await writer.applyDeletePolicy(
          collection,
          (p['ids'] as List).cast<String>(),
        );
      default:
        throw ArgumentError('ImapSyncWriter: unknown op "${p['op']}"');
    }
  }

  static List<String> _splitLabels(String? s) =>
      (s == null || s.isEmpty) ? <String>[] : s.split(',');
}
