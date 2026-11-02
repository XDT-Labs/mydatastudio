import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/folder_sync_planner.dart';

const _stored = StoredFolderSyncState(
  uidValidity: 7,
  uidNext: 11,
  highestModseq: 50,
  lastSyncedUid: 10,
);

ServerFolderState _server({
  int? uidValidity = 7,
  int? uidNext = 11,
  int? highestModseq = 50,
  bool condstore = true,
}) => ServerFolderState(
  uidValidity: uidValidity,
  uidNext: uidNext,
  highestModseq: highestModseq,
  supportsCondstore: condstore,
);

void main() {
  group('FolderSyncPlanner', () {
    test('never-synced folder is a fresh full sync', () {
      final plan = FolderSyncPlanner.plan(
        const StoredFolderSyncState(),
        _server(),
        force: false,
      );
      expect(plan.reset, isTrue);
      expect(plan.skip, isFalse);
      expect(plan.fetchAfterUid, 0);
      expect(
        plan.flagSync,
        FlagSync.none,
        reason: 'flags arrive with the fetch',
      );
    });

    test('changed UIDVALIDITY resets: old UIDs mean nothing', () {
      final plan = FolderSyncPlanner.plan(
        _stored,
        _server(uidValidity: 8),
        force: false,
      );
      expect(plan.reset, isTrue);
      expect(plan.fetchAfterUid, 0);
    });

    test('force ignores stored state', () {
      final plan = FolderSyncPlanner.plan(_stored, _server(), force: true);
      expect(plan.reset, isTrue);
      expect(plan.skip, isFalse);
    });

    test('server without UIDVALIDITY is never trusted incrementally', () {
      final plan = FolderSyncPlanner.plan(
        _stored,
        _server(uidValidity: null),
        force: false,
      );
      expect(plan.reset, isTrue);
    });

    test('unchanged UIDNEXT and MODSEQ skips the folder', () {
      final plan = FolderSyncPlanner.plan(_stored, _server(), force: false);
      expect(plan.skip, isTrue);
      expect(plan.reset, isFalse);
    });

    test('without CONDSTORE nothing can be proven unchanged', () {
      final plan = FolderSyncPlanner.plan(
        _stored,
        _server(condstore: false, highestModseq: null),
        force: false,
      );
      expect(plan.skip, isFalse);
      expect(plan.flagSync, FlagSync.full);
      expect(plan.fetchAfterUid, 10);
    });

    test('new mail fetches only after lastSyncedUid', () {
      final plan = FolderSyncPlanner.plan(
        _stored,
        _server(uidNext: 14, highestModseq: 53),
        force: false,
      );
      expect(plan.reset, isFalse);
      expect(plan.fetchAfterUid, 10);
      expect(plan.flagSync, FlagSync.changedSince);
      expect(plan.changedSinceModseq, 50);
    });

    test(
      'CONDSTORE without a stored modseq falls back to a full flag pass',
      () {
        final plan = FolderSyncPlanner.plan(
          const StoredFolderSyncState(
            uidValidity: 7,
            uidNext: 11,
            lastSyncedUid: 10,
          ),
          _server(highestModseq: 60),
          force: false,
        );
        expect(plan.flagSync, FlagSync.full);
      },
    );

    test(
      'a half-finished first sync (no uidNext/modseq) is resumed, not skipped',
      () {
        final plan = FolderSyncPlanner.plan(
          const StoredFolderSyncState(uidValidity: 7, lastSyncedUid: 40),
          _server(),
          force: false,
        );
        expect(plan.skip, isFalse);
        expect(plan.fetchAfterUid, 40);
      },
    );
  });
}
