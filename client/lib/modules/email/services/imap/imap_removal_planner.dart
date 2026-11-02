/// A locally stored message as the removal planner sees it.
class LocalImapRow {
  const LocalImapRow({
    required this.id,
    required this.uid,
    required this.messageId,
    required this.labels,
  });

  final String id;
  final int? uid;
  final String? messageId;

  /// Other folders (besides the row's own `folder_id`) that also hold it.
  final List<String> labels;
}

/// Pure selection of which local rows a folder sync must treat as gone.
class ImapRemovalPlanner {
  ImapRemovalPlanner._();

  /// Rows of the synced folder that are no longer there.
  ///
  /// A row with a UID is gone when the server no longer lists that UID. A row
  /// *without* a UID matters only after a UIDVALIDITY reset ([afterReset]):
  /// the reset cleared every UID, the full re-fetch re-matched what it could
  /// by Message-ID, and what is still unmatched and has a Message-ID is no
  /// longer on the server. Without a Message-ID there is nothing to re-match
  /// on, so such a row is never declared gone.
  static List<LocalImapRow> vanished(
    List<LocalImapRow> rows,
    Set<int> remoteUids, {
    required bool afterReset,
  }) {
    return rows.where((r) {
      final uid = r.uid;
      if (uid != null) return !remoteUids.contains(uid);
      return afterReset && r.messageId != null;
    }).toList();
  }

  /// Secondary-membership rows (folder listed in `labels`, not their primary)
  /// whose Message-ID the folder no longer holds.
  static List<LocalImapRow> goneFromSecondary(
    List<LocalImapRow> secondaryRows,
    Set<String> remoteMessageIds,
  ) =>
      secondaryRows
          .where(
            (r) =>
                r.messageId != null && !remoteMessageIds.contains(r.messageId),
          )
          .toList();

  /// Cheap gate for the (expensive) header scan: if the server holds at least
  /// as many messages as we can account for locally, no secondary membership
  /// can have disappeared.
  static bool secondaryScanNeeded({
    required int primaryPresent,
    required int secondaryCount,
    required int remoteCount,
  }) => secondaryCount > 0 && primaryPresent + secondaryCount > remoteCount;
}
