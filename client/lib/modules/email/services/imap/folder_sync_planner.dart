/// The sync state persisted per folder (`email_folders` columns).
class StoredFolderSyncState {
  const StoredFolderSyncState({
    this.uidValidity,
    this.uidNext,
    this.highestModseq,
    this.lastSyncedUid,
  });

  final int? uidValidity;
  final int? uidNext;
  final int? highestModseq;
  final int? lastSyncedUid;
}

/// What the server reported when the folder was SELECTed.
class ServerFolderState {
  const ServerFolderState({
    required this.uidValidity,
    required this.uidNext,
    required this.highestModseq,
    required this.supportsCondstore,
  });

  final int? uidValidity;
  final int? uidNext;

  /// Null when the server has no CONDSTORE, or the folder is NOMODSEQ.
  final int? highestModseq;
  final bool supportsCondstore;

  bool get hasModseq => supportsCondstore && highestModseq != null;
}

/// How to find out which already-synced messages changed their flags.
enum FlagSync {
  /// Not needed: flags arrive with the messages being fetched anyway.
  none,

  /// `UID FETCH 1:n (FLAGS) (CHANGEDSINCE modseq)` — CONDSTORE, cheap.
  changedSince,

  /// `UID FETCH 1:n (FLAGS)` — no usable modseq to ask relative to.
  full,
}

class FolderSyncPlan {
  const FolderSyncPlan({
    required this.reset,
    required this.skip,
    required this.fetchAfterUid,
    required this.flagSync,
    this.changedSinceModseq,
  });

  /// Stored state is untrusted: clear it and resync the whole folder.
  final bool reset;

  /// The server proves nothing changed; do no work.
  final bool skip;

  /// Fetch messages with UID strictly greater than this (0 = everything).
  final int fetchAfterUid;
  final FlagSync flagSync;
  final int? changedSinceModseq;
}

/// Pure decision: full vs incremental vs reset, from stored state and the
/// server's SELECT response. No I/O so it can be unit-tested exhaustively.
class FolderSyncPlanner {
  FolderSyncPlanner._();

  static FolderSyncPlan plan(
    StoredFolderSyncState stored,
    ServerFolderState server, {
    required bool force,
  }) {
    // A UID is only meaningful within one UIDVALIDITY (RFC 3501 2.3.1.1). A
    // server that does not report one cannot be synced incrementally.
    final reset =
        force ||
        server.uidValidity == null ||
        stored.uidValidity == null ||
        stored.uidValidity != server.uidValidity;
    if (reset) {
      return const FolderSyncPlan(
        reset: true,
        skip: false,
        fetchAfterUid: 0,
        flagSync: FlagSync.none,
      );
    }

    // uidNext/modseq are only stored once a sync finished, so equality with
    // the server proves nothing was added, changed or expunged since.
    final unchanged =
        server.hasModseq &&
        stored.highestModseq == server.highestModseq &&
        stored.uidNext != null &&
        stored.uidNext == server.uidNext;
    final FlagSync flagSync;
    if (server.hasModseq && stored.highestModseq != null) {
      flagSync = FlagSync.changedSince;
    } else {
      flagSync = FlagSync.full;
    }
    return FolderSyncPlan(
      reset: false,
      skip: unchanged,
      fetchAfterUid: stored.lastSyncedUid ?? 0,
      flagSync: flagSync,
      changedSinceModseq:
          flagSync == FlagSync.changedSince ? stored.highestModseq : null,
    );
  }
}
