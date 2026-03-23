import 'package:mydatatools/app_logger.dart';
import 'package:mydatatools/database_manager.dart';
import 'package:mydatatools/models/tables/email.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:drift/drift.dart';

class EmailRepository {
  final AppDatabase database;
  AppLogger logger = AppLogger(null);

  EmailRepository(this.database);

  Future<List<model.File>> getAttachments(String emailId) async {
    return await (database.select(database.files)
          ..where((f) => f.emailId.equals(emailId)))
        .get();
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

    final query = database.select(database.emails)
      ..where((e) => e.collectionId.equals(collectionId))
      ..where((e) {
        if (folderId != null) {
          return e.folderId.equals(folderId);
        }
        return const Constant(true);
      })
      ..where((e) {
        if (search != null && search.isNotEmpty) {
          return e.subject.contains(search) | e.from.contains(search) | e.snippet.contains(search);
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
        }
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
    return await (database
            .customSelect(
              'SELECT COUNT(*) AS c FROM emails WHERE collectionId = ?',
              variables: [Variable.withString(collectionId)],
              readsFrom: {database.emails},
            ))
            .map((row) => row.read<int>('c'))
            .getSingle();
  }

  Future<DateTime?> getMinEmailDate(String collectionId) async {
    Email? email = await (database.select(database.emails)
          ..where((e) => e.collectionId.equals(collectionId))
          ..orderBy([(t) => OrderingTerm(expression: t.date, mode: OrderingMode.asc)])
          ..limit(1))
        .getSingleOrNull();
    return email?.date;
  }

  Future<DateTime?> getMaxEmailDate(String collectionId) async {
    Email? email = await (database.select(database.emails)
          ..where((e) => e.collectionId.equals(collectionId))
          ..orderBy([(t) => OrderingTerm(expression: t.date, mode: OrderingMode.desc)])
          ..limit(1))
        .getSingleOrNull();
    return email?.date;
  }

  Future<List<Email>> getAllById(List<String> ids) async {
    List<Email> emails = [];
    if (ids.isNotEmpty) {
      emails = await (database.select(database.emails)
            ..where((e) => e.id.isIn(ids)))
          .get();
    }

    return emails;
  }

  Future<void> addEmails(List<Email> emails) async {
    await database.batch((batch) {
      batch.insertAllOnConflictUpdate(database.emails, emails);
    });
  }

  Future<void> deleteEmails(List<Email> emails) async {
    await database.batch((batch) {
      for (var e in emails) {
        batch.delete(database.emails, e);
      }
    });
  }
}
