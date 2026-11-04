import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_removal_planner.dart';

LocalImapRow _row(String id, int? uid, {String? mid, List<String>? labels}) =>
    LocalImapRow(
      id: id,
      uid: uid,
      messageId: mid ?? '<$id>',
      labels: labels ?? [],
    );

void main() {
  group('ImapRemovalPlanner.vanished', () {
    test('rows whose UID the server no longer lists are gone', () {
      final gone = ImapRemovalPlanner.vanished(
        [_row('a', 1), _row('b', 2), _row('c', 3)],
        {1, 3},
        afterReset: false,
      );
      expect(gone.map((r) => r.id), ['b']);
    });

    test('a row without a UID is not gone in a normal sync', () {
      expect(
        ImapRemovalPlanner.vanished([_row('a', null)], {1}, afterReset: false),
        isEmpty,
      );
    });

    test('after a UIDVALIDITY reset an unmatched row with a Message-ID is gone '
        '(it could not be re-matched by Message-ID)', () {
      final gone = ImapRemovalPlanner.vanished(
        [_row('a', null), _row('b', 5)],
        {5},
        afterReset: true,
      );
      expect(gone.map((r) => r.id), ['a']);
    });

    test('after a reset a row with no Message-ID is never declared gone', () {
      final noId = LocalImapRow(
        id: 'x',
        uid: null,
        messageId: null,
        labels: [],
      );
      expect(
        ImapRemovalPlanner.vanished([noId], {1}, afterReset: true),
        isEmpty,
        reason: 'it cannot be re-matched, so absence proves nothing',
      );
    });
  });

  group('secondary membership', () {
    test('rows whose Message-ID the folder lacks are dropped from it', () {
      final gone = ImapRemovalPlanner.goneFromSecondary(
        [_row('a', null, mid: '<m1>'), _row('b', null, mid: '<m2>')],
        {'<m2>'},
      );
      expect(gone.map((r) => r.id), ['a']);
    });

    test(
      'header scan is only worth it when local accounts exceed the server',
      () {
        expect(
          ImapRemovalPlanner.secondaryScanNeeded(
            primaryPresent: 3,
            secondaryCount: 2,
            remoteCount: 5,
          ),
          isFalse,
        );
        expect(
          ImapRemovalPlanner.secondaryScanNeeded(
            primaryPresent: 3,
            secondaryCount: 2,
            remoteCount: 4,
          ),
          isTrue,
        );
        expect(
          ImapRemovalPlanner.secondaryScanNeeded(
            primaryPresent: 3,
            secondaryCount: 0,
            remoteCount: 1,
          ),
          isFalse,
        );
      },
    );
  });
}
