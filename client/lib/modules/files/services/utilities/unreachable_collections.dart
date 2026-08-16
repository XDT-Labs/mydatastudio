/// Backs off a whole collection while its storage is unreachable.
///
/// The problem it solves, measured on this archive: a NAS was disconnected, and
/// one photo under it was re-selected and re-read every 10 seconds — 285 times
/// in a few hours, and it would have continued for the life of the archive.
/// Nothing about the file was ever going to change while the volume was away.
///
/// **Deliberately in memory only.** The obvious alternative is to spend the
/// file's `embedding_attempts` budget, and that is exactly the mistake the
/// budget's own documentation warns against: five passes during an outage
/// retire the photo permanently, and it stays retired after the volume comes
/// back, with nothing in the UI to say a photo was dropped from search. Holding
/// this in memory means the worst case is a delay, and a restart forgets
/// everything.
///
/// **Per collection, not per file.** A volume does not go away one photo at a
/// time. Keying on the collection makes the deferred set small and bounded
/// (three entries on this archive, against the thousands of files under them),
/// turns thousands of failed reads into one, and — because the deferred ids are
/// excluded from the query rather than skipped after it — stops an offline NAS
/// from filling every batch and starving the files that *are* readable.
///
/// Classifying the failure instead was tried and abandoned: it is not reliably
/// possible. macOS leaves a skeleton of directories under `/Volumes` when a
/// mount drops, so "the collection root exists" can be true for a volume that
/// is not there, and a check built on it would retire photos during precisely
/// the outage it was meant to survive.
class UnreachableCollections {
  UnreachableCollections({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _deferrals = <String, _Deferral>{};

  /// Wait after the first failure. Short, because most read failures are not
  /// outages at all and a brief pause costs nothing.
  static const initialBackoff = Duration(minutes: 1);

  /// Ceiling on the wait. A disconnected NAS may be away for days; checking
  /// every half hour costs one failed read per collection and picks the volume
  /// back up soon after it returns.
  static const maxBackoff = Duration(minutes: 30);

  /// Records that a file in [collectionId] could not be read.
  ///
  /// Returns true when this starts a new deferral, so the caller can log once
  /// per outage rather than once per file — the log noise was half the
  /// original symptom.
  bool recordFailure(String collectionId) {
    final existing = _deferrals[collectionId];
    final failures = (existing?.failures ?? 0) + 1;
    final backoff = _backoffFor(failures);
    _deferrals[collectionId] = _Deferral(
      failures: failures,
      until: _now().add(backoff),
    );
    return existing == null;
  }

  /// Records that a file in [collectionId] was read, clearing any backoff.
  ///
  /// A single success proves the storage is back, and the next batch should
  /// see the whole collection again rather than wait out a backoff computed
  /// while it was away.
  void recordSuccess(String collectionId) => _deferrals.remove(collectionId);

  /// Collections that should be left out of the next batch.
  ///
  /// An expired deferral is *filtered*, not forgotten. Dropping the entry would
  /// take the failure count with it, so the next failure would start the
  /// schedule over at one minute — and a volume that is simply gone would be
  /// polled every minute for the life of the app, which is the behaviour this
  /// class exists to end. Only a success clears the count, because only a
  /// success is evidence the storage is back.
  Set<String> deferred() {
    final now = _now();
    return {
      for (final entry in _deferrals.entries)
        if (entry.value.until.isAfter(now)) entry.key,
    };
  }

  /// How long [failures] consecutive failures should be waited out.
  ///
  /// Doubling, capped. Exposed for the test that pins the schedule: the shape
  /// of the curve is the whole design, and a linear one would still be reading
  /// an absent NAS hundreds of times a day.
  static Duration _backoffFor(int failures) {
    final doubled = initialBackoff * (1 << (failures - 1).clamp(0, 16));
    return doubled > maxBackoff ? maxBackoff : doubled;
  }

  /// Visible for testing the schedule directly.
  static Duration backoffFor(int failures) => _backoffFor(failures);
}

class _Deferral {
  const _Deferral({required this.failures, required this.until});
  final int failures;
  final DateTime until;
}
