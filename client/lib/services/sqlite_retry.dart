import 'package:resqlite/resqlite.dart'
    show
        ResqliteException,
        ResqliteQueryException,
        ResqliteTransactionException;

/// SQLite result codes worth retrying: 5 SQLITE_BUSY, 6 SQLITE_LOCKED.
///
/// Both mean another writer holds the lock at this instant, not that the write
/// is invalid — the same statement will succeed shortly. Every other code is a
/// real error and must surface.
const Set<int> retryableSqliteCodes = {5, 6};

/// The SQLite result code carried by a resqlite exception, or null.
///
/// [ResqliteQueryException] and [ResqliteTransactionException] are *siblings*
/// under [ResqliteException], not parent and child, and each declares its own
/// `sqliteCode`. Nothing in the type system connects them.
int? sqliteCodeOf(Object e) {
  if (e is ResqliteQueryException) return e.sqliteCode;
  if (e is ResqliteTransactionException) return e.sqliteCode;
  return null;
}

/// Whether [e] is transient lock contention that is worth retrying.
///
/// Exists because the sibling relationship above is a genuine trap. Repository
/// methods that wrap their writes in `database.transaction(...)` fail with
/// `ResqliteTransactionException: database is locked` (operation 'begin'), which
/// an `on ResqliteQueryException` clause does not catch. A retry written that
/// way compiles, reads correctly, and silently does nothing — a PST import
/// dropped two of 1181 emails on two consecutive runs before the distinction
/// was noticed.
bool isRetryableLockError(Object e) =>
    e is ResqliteException && retryableSqliteCodes.contains(sqliteCodeOf(e));
