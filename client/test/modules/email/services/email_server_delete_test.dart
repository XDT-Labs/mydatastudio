import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/services/email_server_delete.dart';
import 'package:mydatastudio/scanners/collection_scanner.dart';

import '../../../helpers/email_fixture.dart';

class _FakeScanner extends CollectionScanner {
  _FakeScanner({this.failingFolders = const {}, this.throwing = false});

  final Set<String> failingFolders;
  final bool throwing;
  final calls = <(String, List<int>, Map<String, List<String>>)>[];

  @override
  Future<bool> moveToTrash(
    Collection collection,
    String folderId,
    List<int> uids, {
    Map<String, List<String>> otherCopies = const {},
  }) async {
    if (throwing) throw StateError('offline');
    calls.add((folderId, uids, otherCopies));
    return !failingFolders.contains(folderId);
  }
}

final _collection = Collection(
  id: 'c',
  name: 'c',
  path: '',
  type: 'email',
  scanner: 'email.imap',
  scanStatus: 'idle',
  needsReAuth: false,
);

Email _mail(String id, String folder, int? uid, {List<String>? labels}) =>
    makeTestEmail(
      id: id,
      folderId: folder,
      uid: uid,
      labels: labels,
      messageId: '<$id@test>',
    );

void main() {
  test('only mail that reached the trash may be deleted locally', () async {
    // Anything else is still on the server and the next sync would restore it,
    // so deleting it here would look like a delete that quietly undid itself.
    final scanner = _FakeScanner(failingFolders: {'Sent'});
    final moved = await moveToServerTrash(
      [_mail('a', 'INBOX', 1), _mail('b', 'Sent', 2)],
      _collection,
      scanner,
    );
    expect(moved.map((e) => e.id), ['a']);
  });

  test('a scanner error keeps the mail', () async {
    final moved = await moveToServerTrash(
      [_mail('a', 'INBOX', 1)],
      _collection,
      _FakeScanner(throwing: true),
    );
    expect(moved, isEmpty);
  });

  test('mail with no UID stays, since the server cannot be asked', () async {
    final scanner = _FakeScanner();
    final moved = await moveToServerTrash(
      [_mail('a', 'INBOX', null)],
      _collection,
      scanner,
    );
    expect(moved, isEmpty);
    expect(scanner.calls, isEmpty);
  });

  test('copies in other folders are sent too', () async {
    // A copy left behind would be matched by Message-ID and restored on sync.
    final scanner = _FakeScanner();
    await moveToServerTrash(
      [
        _mail('a', 'INBOX', 1, labels: ['Work', 'INBOX']),
      ],
      _collection,
      scanner,
    );
    final (folder, uids, otherCopies) = scanner.calls.single;
    expect(folder, 'INBOX');
    expect(uids, [1]);
    expect(otherCopies, {
      'Work': ['<a@test>'],
    });
  });
}
