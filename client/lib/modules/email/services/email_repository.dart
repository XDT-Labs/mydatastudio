import 'dart:io' as io;
import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:drift/drift.dart';
import 'package:mydatatools/models/tables/collection.dart';
import 'package:mydatatools/modules/files/services/repositories/file_repository.dart';
// removed unused import

class EmailRepository {
  final AppDatabase database;
  AppLogger logger = AppLogger(null);

  EmailRepository(this.database);

  Future<List<model.File>> getAttachments(String emailId) async {
    return await (database.select(database.files)
      ..where((f) => f.emailId.equals(emailId))).get();
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

    final query =
        database.select(database.emails)
          ..where((e) => e.collectionId.equals(collectionId))
          ..where((e) {
            if (folderId != null) {
              return e.folderId.equals(folderId);
            }
            return const Constant(true);
          })
          ..where((e) {
            if (search != null && search.isNotEmpty) {
              return e.subject.contains(search) |
                  e.from.contains(search) |
                  e.snippet.contains(search);
            }
            return const Constant(true);
          })
          ..orderBy([
            (t) {
              Expression column;
              if (sortColumn == 'from') {
                column = t.from;
              } else if (sortColumn == 'subject') {
                column = t.subject;
              } else {
                column = t.date;
              }
              return OrderingTerm(
                expression: column,
                mode: sortAsc! ? OrderingMode.asc : OrderingMode.desc,
              );
            },
          ]);

    // Only apply pagination when limit > 0. Pass limit = -1 to get all rows
    // (e.g. for export). Default is 100 to avoid loading thousands of Drift
    // rows onto the main thread at once.
    if (limit > 0) {
      query.limit(limit, offset: offset);
    }

    return await query.get();
  }

  Future<int> emailCount(String collectionId) async {
    return await (database.customSelect(
      'SELECT COUNT(*) AS c FROM emails WHERE collectionId = ?',
      variables: [Variable.withString(collectionId)],
      readsFrom: {database.emails},
    )).map((row) => row.read<int>('c')).getSingle();
  }

  Future<DateTime?> getMinEmailDate(String collectionId) async {
    Email? email =
        await (database.select(database.emails)
              ..where((e) => e.collectionId.equals(collectionId))
              ..orderBy([
                (t) => OrderingTerm(expression: t.date, mode: OrderingMode.asc),
              ])
              ..limit(1))
            .getSingleOrNull();
    return email?.date;
  }

  Future<DateTime?> getMaxEmailDate(String collectionId) async {
    Email? email =
        await (database.select(database.emails)
              ..where((e) => e.collectionId.equals(collectionId))
              ..orderBy([
                (t) =>
                    OrderingTerm(expression: t.date, mode: OrderingMode.desc),
              ])
              ..limit(1))
            .getSingleOrNull();
    return email?.date;
  }

  Future<List<Email>> getAllById(List<String> ids) async {
    List<Email> emails = [];
    if (ids.isNotEmpty) {
      emails =
          await (database.select(database.emails)
            ..where((e) => e.id.isIn(ids))).get();
    }

    return emails;
  }

  Future<void> addEmails(List<Email> emails) async {
    await database.batch((batch) {
      batch.insertAllOnConflictUpdate(database.emails, emails);
    });
  }

  Future<void> deleteEmails(List<String> ids) async {
    if (ids.isEmpty) return;

    final fileRepo = FileDesktopRepository(database);
    try {
      // 1. Get all associated files in one query
      final files = await fileRepo.getByEmailIds(ids);

      // 2. Delete physical files from filesystem
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

      // 3. Delete File entries from DB (bulk)
      if (files.isNotEmpty) {
        final fileIds = files.map((f) => f.id).toList();
        await (database.delete(database.files)
          ..where((t) => t.id.isIn(fileIds))).go();
      }

      // 4. Delete the email records (bulk)
      await (database.delete(database.emails)
        ..where((t) => t.id.isIn(ids))).go();
    } catch (err) {
      logger.e("Error during bulk email deletion: $err");
    }
  }

  Future<void> cleanupDeletedYahoo(
    Collection collection,
    String folder,
    List<int> remoteUids,
  ) async {
    // 1. Get all local email IDs and UIDs for this folder
    final query =
        database.selectOnly(database.emails)
          ..addColumns([database.emails.id, database.emails.uid])
          ..where(
            database.emails.collectionId.equals(collection.id) &
                database.emails.folderId.equals(folder),
          );

    final rows = await query.get();
    final localEmails =
        rows
            .map(
              (row) => (
                id: row.read(database.emails.id)!,
                uid: row.read(database.emails.uid),
              ),
            )
            .toList();

    // 2. Find missing emails by UID
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
    // 1. Get all local email IDs and UIDs for this folder
    final query =
        database.selectOnly(database.emails)
          ..addColumns([database.emails.id, database.emails.uid])
          ..where(
            database.emails.collectionId.equals(collection.id) &
                database.emails.folderId.equals(folder),
          );

    final rows = await query.get();
    final localEmails =
        rows
            .map(
              (row) => (
                id: row.read(database.emails.id)!,
                uid: row.read(database.emails.uid),
              ),
            )
            .toList();

    // 2. Find missing emails by UID
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
