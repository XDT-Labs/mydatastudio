import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';

/// A PST import writes to the database from its own isolate; nothing tells the
/// email page the rows landed. Every case below is a way that either leaves the
/// user staring at an empty list or rebuilds the list out from under them.
void main() {
  const collectionId = 'collection-1';
  const pageSize = 100;
  final now = DateTime(2026, 7, 27, 12, 0, 0);

  PstImportProgress progress({
    String id = collectionId,
    bool done = false,
    int examined = 50,
  }) {
    return PstImportProgress(
      collectionId: id,
      collectionName: 'Archive',
      totalMessages: 1000,
      examined: examined,
      emails: examined,
      done: done,
    );
  }

  bool decide({
    PstImportProgress? value,
    bool hasOpenEmail = false,
    int loadedCount = 0,
    DateTime? lastRefresh,
  }) {
    return shouldRefreshForImport(
      progress: value,
      currentCollectionId: collectionId,
      hasOpenEmail: hasOpenEmail,
      loadedCount: loadedCount,
      pageSize: pageSize,
      now: now,
      lastRefresh: lastRefresh,
    );
  }

  group('shouldRefreshForImport', () {
    test('a finished import always refreshes', () {
      // The bug this whole policy exists for: the import ended, the progress
      // bar vanished, and the list stayed empty until the collection was
      // clicked again.
      expect(decide(value: progress(done: true)), isTrue);
    });

    test('a finished import refreshes even while a message is open', () {
      // The open message is stale by then — it may not even be in the folder
      // the final list shows.
      expect(
        decide(value: progress(done: true), hasOpenEmail: true),
        isTrue,
      );
    });

    test('a finished import refreshes despite the throttle', () {
      expect(
        decide(
          value: progress(done: true),
          lastRefresh: now.subtract(const Duration(milliseconds: 10)),
        ),
        isTrue,
      );
    });

    test('a finished import refreshes even with a full page loaded', () {
      expect(
        decide(value: progress(done: true), loadedCount: pageSize),
        isTrue,
      );
    });

    test('an in-flight import refreshes so messages appear as they land', () {
      expect(decide(value: progress()), isTrue);
    });

    test('an import for another collection is ignored', () {
      expect(decide(value: progress(id: 'other-collection')), isFalse);
    });

    test('no import means nothing to refresh for', () {
      expect(decide(value: null), isFalse);
    });

    test('does not rebuild the list while a message is open', () {
      expect(decide(value: progress(), hasOpenEmail: true), isFalse);
    });

    test('stops once a full page is on screen', () {
      // Past this point the scroll handler pages in more; refreshing would
      // throw away the reader's scroll position for nothing.
      expect(decide(value: progress(), loadedCount: pageSize), isFalse);
      expect(decide(value: progress(), loadedCount: pageSize + 1), isFalse);
    });

    test('still refreshes on a partly filled page', () {
      expect(decide(value: progress(), loadedCount: pageSize - 1), isTrue);
    });

    test('throttles repeated progress updates', () {
      // Progress arrives every fifty messages; on a multi-gigabyte archive
      // that is far more often than the list can usefully be rebuilt.
      expect(
        decide(
          value: progress(),
          lastRefresh: now.subtract(const Duration(milliseconds: 500)),
        ),
        isFalse,
      );
    });

    test('refreshes again once the throttle window has passed', () {
      expect(
        decide(
          value: progress(),
          lastRefresh: now.subtract(const Duration(seconds: 3)),
        ),
        isTrue,
      );
    });
  });
}
