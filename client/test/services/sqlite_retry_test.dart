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

  group('retryOnLock', () {
    ResqliteTransactionException lock() => ResqliteTransactionException(
      'database is locked',
      operation: 'begin',
      sqliteCode: 5,
    );

    test('returns the value when the first attempt succeeds', () async {
      var calls = 0;
      final result = await retryOnLock(() async {
        calls++;
        return 'ok';
      }, label: 'test');

      expect(result, 'ok');
      expect(calls, 1, reason: 'must not retry a successful call');
    });

    test('succeeds after transient locks, which is the whole point', () async {
      var calls = 0;
      final result = await retryOnLock(() async {
        calls++;
        if (calls < 3) throw lock();
        return 'ok';
      }, label: 'test', baseDelay: Duration.zero);

      expect(result, 'ok');
      expect(calls, 3);
    });

    test('rethrows once the retry budget is exhausted', () async {
      var calls = 0;
      await expectLater(
        retryOnLock(() async {
          calls++;
          throw lock();
        }, label: 'test', maxRetries: 3, baseDelay: Duration.zero),
        throwsA(isA<ResqliteTransactionException>()),
      );

      // 1 initial attempt + 3 retries. A caller that loses data must find out.
      expect(calls, 4);
    });

    test('does not retry a constraint violation', () async {
      var calls = 0;
      await expectLater(
        retryOnLock(() async {
          calls++;
          throw ResqliteQueryException(
            'UNIQUE constraint failed',
            sql: 'INSERT ...',
            sqliteCode: 19,
          );
        }, label: 'test', baseDelay: Duration.zero),
        throwsA(isA<ResqliteQueryException>()),
      );

      expect(calls, 1, reason: 'a real error must surface immediately');
    });

    test('does not swallow an unrelated error', () async {
      var calls = 0;
      await expectLater(
        retryOnLock(() async {
          calls++;
          throw StateError('unrelated');
        }, label: 'test', baseDelay: Duration.zero),
        throwsA(isA<StateError>()),
      );

      expect(calls, 1);
    });
  });
}
