// [ignoring loop detection]
import 'dart:io' as io;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
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
      query += "AND (folder_id = ? OR ',' || labels || ',' LIKE ?) ";
      args.add(folderId);
      args.add('%,$folderId,%');
    }

    if (search != null && search.isNotEmpty) {
      query += "AND (subject LIKE ? OR [from] LIKE ? OR snippet LIKE ?) ";
      args.add('%$search%');
      args.add('%$search%');
      args.add('%$search%');
    }

    String colName = 'date';
    if (sortColumn == 'from') {
      colName = '[from]';
    } else if (sortColumn == 'subject') {
      colName = 'subject';
    }
    query += "ORDER BY $colName ${sortAsc ? 'ASC' : 'DESC'} ";

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

  Future<void> deleteEmails(List<String> ids) async {
    if (ids.isEmpty) return;

    final fileRepo = FileDesktopRepository(database);
    try {
      final files = await fileRepo.getByEmailIds(ids);

      for (var f in files) {
        try {
          final ioFile = io.File(f.path);
          if (await ioFile.exists()) {
            await ioFile.delete();
          }
        } catch (err) {
          logger.e("Error deleting attachment file at ${f.path}: $err");
        }
      }

      await database.transaction((tx) async {
        if (files.isNotEmpty) {
          final fileIds = files.map((f) => f.id).toList();
          final placeholders = List.filled(fileIds.length, '?').join(',');
          await tx.execute(
            "DELETE FROM files WHERE id IN ($placeholders)",
            fileIds,
          );
        }

        final emailPlaceholders = List.filled(ids.length, '?').join(',');
        await tx.execute(
          "DELETE FROM emails WHERE id IN ($emailPlaceholders)",
          ids,
        );
      });
    } catch (err) {
      logger.e("Error during bulk email deletion: $err");
    }
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
      await deleteEmails(toDeleteIds);
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
      await deleteEmails(toDeleteIds);
    }
  }
}
