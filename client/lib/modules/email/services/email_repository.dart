// [ignoring loop detection]
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/helpers/sql_chunks.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';

class EmailRepository {
  final AppDatabase database;
  AppLogger logger = AppLogger(null);

  EmailRepository(this.database);

  Future<List<model.File>> getAttachments(String emailId) async {
    final rows = await database.select(
      "SELECT * FROM files WHERE email_id = ?",
      [emailId],
    );
    return rows.map((r) => model.File.fromDbMap(r)).toList();
  }

  Future<List<Email>> emails(
    String collectionId, {
    String? folderId,
    String? search,
    String? sortColumn,
    bool? sortAsc,
    int limit = 100,
    int offset = 0,
  }) async {
    sortColumn ??= "date";
    sortAsc ??= false;

    String query = "SELECT * FROM emails WHERE collection_id = ? ";
    List<dynamic> args = [collectionId];

    if (folderId != null) {
      // instr(), not LIKE: Gmail label ids routinely contain '_' (Label_12),
      // which LIKE reads as "any single character" — so a folder filter could
      // match a different label differing only at that position.
      query += "AND (folder_id = ? OR instr(',' || labels || ',', ?) > 0) ";
      args.add(folderId);
      args.add(',$folderId,');
    }

    if (search != null && search.isNotEmpty) {
      query += "AND (subject LIKE ? OR [from] LIKE ? OR snippet LIKE ?) ";
      args.add('%$search%');
      args.add('%$search%');
      args.add('%$search%');
    }

    // Sorting is done here, in SQL, over the whole folder — never over the page
    // already in memory, which would only order the hundred rows loaded so far.
    // COLLATE NOCASE on the text columns because SQLite's default BINARY
    // collation orders by byte, which files every lowercase sender after every
    // uppercase one.
    String orderBy = 'date';
    if (sortColumn == 'from') {
      orderBy = '[from] COLLATE NOCASE';
    } else if (sortColumn == 'subject') {
      orderBy = 'subject COLLATE NOCASE';
    }
    // `id` breaks ties. Without it SQLite is free to return rows sharing a sort
    // value in a different order per execution, and this query is paged with
    // LIMIT/OFFSET — so a bulk import that stamps thousands of messages with
    // the same date could show one of them twice and hide another entirely as
    // the user scrolls.
    query += "ORDER BY $orderBy ${sortAsc ? 'ASC' : 'DESC'}, id ASC ";

    if (limit > 0) {
      query += "LIMIT ? OFFSET ? ";
      args.add(limit);
      args.add(offset);
    }

    final rows = await database.select(query, args);
    return rows.map((r) => Email.fromDbMap(r)).toList();
  }

  Future<int> emailCount(String collectionId) async {
    final rows = await database.select(
      "SELECT COUNT(*) AS c FROM emails WHERE collection_id = ?",
      [collectionId],
    );
    if (rows.isEmpty) return 0;
    return rows.first['c'] as int;
  }

  Future<DateTime?> getMinEmailDate(String collectionId) async {
    final rows = await database.select(
      "SELECT * FROM emails WHERE collection_id = ? ORDER BY date ASC LIMIT 1",
      [collectionId],
    );
    if (rows.isEmpty) return null;
    return Email.fromDbMap(rows.first).date;
  }

  Future<DateTime?> getMaxEmailDate(String collectionId) async {
    final rows = await database.select(
      "SELECT * FROM emails WHERE collection_id = ? ORDER BY date DESC LIMIT 1",
      [collectionId],
    );
    if (rows.isEmpty) return null;
    return Email.fromDbMap(rows.first).date;
  }

  Future<List<Email>> getAllById(List<String> ids) async {
    if (ids.isEmpty) return [];
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await database.select(
      "SELECT * FROM emails WHERE id IN ($placeholders)",
      ids,
    );
    return rows.map((r) => Email.fromDbMap(r)).toList();
  }

  Future<void> addEmails(List<Email> emails) async {
    if (emails.isEmpty) return;
    await database.transaction((tx) async {
      for (final e in emails) {
        await tx.execute(
          "INSERT INTO emails (id, collection_id, date, [from], [to], cc, subject, snippet, "
          "html_body, plain_body, labels, headers, folder_id, message_id, thread_id, uid, "
          "is_read, has_attachments, is_deleted) "
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) "
          "ON CONFLICT(id) DO UPDATE SET "
          "collection_id = excluded.collection_id, "
          "date = excluded.date, "
          "[from] = excluded.[from], "
          "[to] = excluded.[to], "
          "cc = excluded.cc, "
          "subject = excluded.subject, "
          "snippet = excluded.snippet, "
          "html_body = excluded.html_body, "
          "plain_body = excluded.plain_body, "
          "labels = excluded.labels, "
          "headers = excluded.headers, "
          "folder_id = excluded.folder_id, "
          "message_id = excluded.message_id, "
          "thread_id = excluded.thread_id, "
          "uid = excluded.uid, "
          "is_read = excluded.is_read, "
          "has_attachments = excluded.has_attachments, "
          "is_deleted = excluded.is_deleted",
          [
            e.id,
            e.collectionId,
            e.date.millisecondsSinceEpoch,
            e.from,
            e.to.join(','),
            (e.cc ?? []).join(','),
            e.subject,
            e.snippet,
            e.htmlBody,
            e.plainBody,
            (e.labels ?? []).join(','),
            e.headers,
            e.folderId,
            e.messageId,
            e.threadId,
            e.uid,
            e.isRead ? 1 : 0,
            e.hasAttachments ? 1 : 0,
            e.isDeleted ? 1 : 0,
          ],
        );
      }
    });
  }

  /// Permanently removes [ids] and everything hanging off them: each message's
  /// attachments — bytes, cached thumbnail, row — and both embeddings.
  ///
  /// The embeddings go by cascade; nothing on disk does, which is why the
  /// attachments are routed through [FileDesktopRepository.deleteFiles] rather
  /// than deleted here with a `DELETE FROM files`.
  ///
  /// [collection] resolves the attachments' stored (relative) paths. Throws on
  /// failure so callers don't report a delete that didn't happen.
  Future<void> deleteEmails(List<String> ids, {Collection? collection}) async {
    if (ids.isEmpty) return;

    final fileRepo = FileDesktopRepository(database);
    // Deliberately not filtered by `is_deleted`: a soft-deleted attachment is
    // exactly the row that would otherwise be stranded, pointing at an email
    // that no longer exists.
    final files = await fileRepo.getByEmailIds(ids, includeDeleted: true);
    await fileRepo.deleteFiles(files, collection: collection);

    await database.transaction((tx) async {
      for (final chunk in sqlChunks(ids)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        await tx.execute(
          "DELETE FROM emails WHERE id IN ($placeholders)",
          chunk,
        );
      }
    });
  }

  Future<void> cleanupDeletedYahoo(
    Collection collection,
    String folder,
    List<int> remoteUids,
  ) async {
    final rows = await database.select(
      "SELECT id, uid FROM emails WHERE collection_id = ? AND folder_id = ?",
      [collection.id, folder],
    );
    final localEmails =
        rows
            .map((row) => (id: row['id'] as String, uid: row['uid'] as int?))
            .toList();

    final remoteUidSet = remoteUids.toSet();
    final toDeleteIds =
        localEmails
            .where((e) {
              if (e.uid == null) return false;
              return !remoteUidSet.contains(e.uid);
            })
            .map((e) => e.id)
            .toList();

    if (toDeleteIds.isNotEmpty) {
      logger.i(
        "Cleanup: Deleting ${toDeleteIds.length} emails locally that were removed from Yahoo folder $folder.",
      );
      await deleteEmails(toDeleteIds, collection: collection);
    }
  }

  Future<void> cleanupDeletedOutlook(
    Collection collection,
    String folder,
    List<int> remoteUids,
  ) async {
    final rows = await database.select(
      "SELECT id, uid FROM emails WHERE collection_id = ? AND folder_id = ?",
      [collection.id, folder],
    );
    final localEmails =
        rows
            .map((row) => (id: row['id'] as String, uid: row['uid'] as int?))
            .toList();

    final remoteUidSet = remoteUids.toSet();
    final toDeleteIds =
        localEmails
            .where((e) {
              if (e.uid == null) return false;
              return !remoteUidSet.contains(e.uid);
            })
            .map((e) => e.id)
            .toList();

    if (toDeleteIds.isNotEmpty) {
      logger.i(
        "Cleanup: Deleting ${toDeleteIds.length} emails locally that were removed from Outlook folder $folder.",
      );
      await deleteEmails(toDeleteIds, collection: collection);
    }
  }
}
