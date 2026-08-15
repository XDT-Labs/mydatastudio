import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/services/utilities/unreachable_collections.dart';

/// Backing off an offline volume without ever giving up on it.
///
/// Both failure directions are silent. Back off too little and a disconnected
/// NAS is re-read every ten seconds forever, filling batches that readable
/// files are waiting for — measured at 285 retries of one photo in a few
/// hours. Persist any of it and an outage retires photos permanently, with
/// nothing in the UI to say they were dropped from search.
void main() {
  late DateTime clock;
  UnreachableCollections build() =>
      UnreachableCollections(now: () => clock);

  setUp(() => clock = DateTime(2026, 8, 12, 9));

  test('a failing collection leaves the queue', () {
    final tracker = build();
    tracker.recordFailure('drobo');

    expect(tracker.deferred(), {'drobo'});
  });

  test('other collections keep running', () {
    // The starvation case. An offline NAS must not stop the local disk from
    // being indexed — which is what happens if the deferral is global, or if
    // deferred files are skipped after the query instead of excluded from it.
    final tracker = build();
    tracker.recordFailure('drobo');

    expect(tracker.deferred(), isNot(contains('local-pictures')));
  });

  test('the collection returns once its backoff expires', () {
    // Never permanent. This is the whole reason the state is in memory and
    // keyed on time rather than counted against the file's attempt budget.
    final tracker = build();
    tracker.recordFailure('drobo');

    clock = clock.add(UnreachableCollections.initialBackoff);
    clock = clock.add(const Duration(seconds: 1));

    expect(tracker.deferred(), isEmpty);
  });

  test('repeated failures back off further, up to a ceiling', () {
    // Doubling, because a NAS may be away for days and a linear schedule
    // would still be reading it hundreds of times a day. Capped, because a
    // volume that comes back should be picked up within the half hour.
    expect(
      UnreachableCollections.backoffFor(1),
      UnreachableCollections.initialBackoff,
    );
    expect(
      UnreachableCollections.backoffFor(2),
      UnreachableCollections.initialBackoff * 2,
    );
    expect(
      UnreachableCollections.backoffFor(3),
      UnreachableCollections.initialBackoff * 4,
    );
    expect(
      UnreachableCollections.backoffFor(50),
      UnreachableCollections.maxBackoff,
    );
  });

  test('the backoff grows across successive outages, not just the first', () {
    final tracker = build();

    tracker.recordFailure('drobo');
    clock = clock.add(UnreachableCollections.initialBackoff * 2);
    expect(tracker.deferred(), isEmpty, reason: 'first backoff expired');

    // Failing again must not restart the schedule at one minute — that is how
    // a permanently absent volume ends up polled every minute forever.
    tracker.recordFailure('drobo');
    clock = clock.add(UnreachableCollections.initialBackoff);
    clock = clock.add(const Duration(seconds: 1));
    expect(tracker.deferred(), {'drobo'});
  });

  test('one success brings the whole collection straight back', () {
    // A backoff computed while the volume was away says nothing once it is
    // back. Waiting it out would leave a reconnected NAS idle for half an
    // hour with the app apparently doing nothing.
    final tracker = build();
    tracker.recordFailure('drobo');
    tracker.recordFailure('drobo');

    tracker.recordSuccess('drobo');

    expect(tracker.deferred(), isEmpty);
  });

  test('only the first failure of an outage is worth announcing', () {
    // The log noise was half the original symptom: thousands of identical
    // lines, one per file per pass.
    final tracker = build();

    expect(tracker.recordFailure('drobo'), isTrue);
    expect(tracker.recordFailure('drobo'), isFalse);
    expect(tracker.recordFailure('drobo'), isFalse);
  });
}
