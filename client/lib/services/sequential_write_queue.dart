import 'dart:async';

import 'package:mydatastudio/app_logger.dart';

/// Runs queued tasks one at a time, in the order they were added.
///
/// [ReceivePort.listen] callbacks fire for each message as it arrives without
/// waiting for a previous callback's `Future` to complete, unlike an
/// `await for` loop over the same port. Scanners that listen this way
/// (Gmail, Outlook, Yahoo, PST) still need their relayed writes processed in
/// order — a folder must land before the files inside it — so this gives
/// them the same "one write at a time, in send order" guarantee the
/// `await for`-based scanners (local filesystem, Google Drive) get for free.
class SequentialWriteQueue {
  Future<void> _tail = Future.value();
  final AppLogger _logger = AppLogger(null);

  /// Schedules [task] after everything already queued, regardless of whether
  /// prior tasks succeeded or failed. A failing task is logged rather than
  /// silently discarded — a task that throws before sending its ack would
  /// otherwise leave the caller awaiting a reply that never arrives, with no
  /// trace of why in the logs.
  void add(Future<void> Function() task) {
    _tail = _tail.then((_) => task()).catchError((Object e, StackTrace st) {
      _logger.e(
        'SequentialWriteQueue: task failed: $e',
        error: e,
        stackTrace: st,
      );
    });
  }
}
