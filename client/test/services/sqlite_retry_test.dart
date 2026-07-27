import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/sqlite_retry.dart';
import 'package:resqlite/resqlite.dart'
    show ResqliteQueryException, ResqliteTransactionException;

void main() {
  group('isRetryableLockError', () {
    test('catches the lock a transaction reports', () {
      // The real failure that dropped PST emails:
      //   ResqliteTransactionException: database is locked  (operation 'begin')
      // Repository methods wrapping writes in database.transaction(...) fail
      // this way, and an `on ResqliteQueryException` clause never sees it.
      final e = ResqliteTransactionException(
        'database is locked',
        operation: 'begin',
        sqliteCode: 5,
      );

      expect(isRetryableLockError(e), isTrue);
    });

    test('a transaction lock is NOT a query exception', () {
      // The trap itself, pinned. These two are siblings, so a retry that
      // catches only the query type compiles, reads correctly, and silently
      // does nothing for anything failing inside a transaction.
      final e = ResqliteTransactionException(
        'database is locked',
        operation: 'begin',
        sqliteCode: 5,
      );

      expect(e, isNot(isA<ResqliteQueryException>()));
    });

    test('catches the lock a plain statement reports', () {
      final e = ResqliteQueryException(
        'database is locked',
        sql: 'INSERT INTO emails ...',
        sqliteCode: 5,
      );

      expect(isRetryableLockError(e), isTrue);
    });

    test('treats SQLITE_LOCKED as retryable too', () {
      final e = ResqliteTransactionException(
        'database table is locked',
        operation: 'begin',
        sqliteCode: 6,
      );

      expect(isRetryableLockError(e), isTrue);
    });

    test('does NOT retry a constraint violation', () {
      // Retrying a genuine error would just burn the budget and still fail,
      // hiding the real cause behind a delay.
      final e = ResqliteQueryException(
        'UNIQUE constraint failed: emails.id',
        sql: 'INSERT INTO emails ...',
        sqliteCode: 19,
      );

      expect(isRetryableLockError(e), isFalse);
    });

    test('does NOT retry an exception carrying no sqlite code', () {
      final e = ResqliteTransactionException('something else', operation: 'commit');

      expect(isRetryableLockError(e), isFalse);
    });

    test('does NOT retry a non-resqlite error', () {
      expect(isRetryableLockError(StateError('unrelated')), isFalse);
    });

    test('extracts the code from either exception type', () {
      expect(
        sqliteCodeOf(
          ResqliteTransactionException('x', operation: 'begin', sqliteCode: 5),
        ),
        5,
      );
      expect(
        sqliteCodeOf(ResqliteQueryException('x', sql: 'y', sqliteCode: 19)),
        19,
      );
      expect(sqliteCodeOf(StateError('z')), isNull);
    });
  });
}
