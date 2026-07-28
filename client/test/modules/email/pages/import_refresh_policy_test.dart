import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';
import 'package:mydatastudio/modules/email/services/scanners/outlook_pst_scanner_isolate.dart';

/// A PST import writes to the database from its own isolate; nothing tells the
/// email page the rows landed. Every case below is a way that either leaves the
/// user staring at an empty list or rebuilds the list out from under them.
void main() {
  const collectionId = 'collection-1';
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

  bool decide({PstImportProgress? value, DateTime? lastRefresh}) {
    return shouldRefreshForImport(
      progress: value,
      currentCollectionId: collectionId,
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

    test('a finished import refreshes despite the throttle', () {
      expect(
        decide(
          value: progress(done: true),
          lastRefresh: now.subtract(const Duration(milliseconds: 10)),
        ),
        isTrue,
      );
    });

    test('an in-flight import refreshes so folders appear as they land', () {
      expect(decide(value: progress()), isTrue);
    });

    test('an import for another collection is ignored', () {
      expect(decide(value: progress(id: 'other-collection')), isFalse);
    });

    test('no import means nothing to refresh for', () {
      expect(decide(value: null), isFalse);
    });

    test('keeps refreshing for the whole import', () {
      // The list is hidden behind the progress placeholder while an import
      // runs, so these refreshes exist to fill in the sidebar's folder tree.
      // An earlier version stopped once a page of messages had loaded, which
      // silently froze the folder list partway through.
      expect(
        decide(
          value: progress(examined: 5000),
          lastRefresh: now.subtract(const Duration(seconds: 10)),
        ),
        isTrue,
      );
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
