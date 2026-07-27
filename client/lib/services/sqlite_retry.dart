import 'package:flutter/foundation.dart';
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

/// Runs [operation], retrying while it fails with transient lock contention.
///
/// The write services all needed this loop and each had grown its own copy with
/// slightly different behaviour — one of which caught the wrong exception type
/// and so never retried at all. Shared here so there is one implementation to
/// get right.
///
/// Retries [maxRetries] times with exponential backoff ([baseDelay] doubling per
/// attempt: 200ms, 400ms, 800ms by default). Anything that is not a retryable
/// lock, and any lock still failing after the last attempt, is rethrown — the
/// caller must decide what a lost write means, and for a one-shot import it
/// means lost data.
///
/// [operation] must be idempotent: it can run several times. Every current
/// caller is an `ON CONFLICT ... DO UPDATE` upsert, which is.
Future<T> retryOnLock<T>(
  Future<T> Function() operation, {
  required String label,
  int maxRetries = 3,
  Duration baseDelay = const Duration(milliseconds: 200),
}) async {
  for (int attempt = 0; ; attempt++) {
    try {
      return await operation();
    } on ResqliteException catch (e) {
      if (!isRetryableLockError(e) || attempt >= maxRetries) rethrow;
      final delay = baseDelay * (1 << attempt);
      debugPrint(
        '$label: sqlite code ${sqliteCodeOf(e)} '
        '(attempt ${attempt + 1}/$maxRetries), '
        'retrying in ${delay.inMilliseconds}ms...',
      );
      await Future.delayed(delay);
    }
  }
}
