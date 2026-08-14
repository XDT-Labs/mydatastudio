import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/email_folder.dart';
import 'package:mydatastudio/modules/email/pages/email_page.dart';

/// The Photos info sidebar links an attachment back to the message that
/// carried it by pushing that message onto [EmailPage.openEmailRequest] and
/// routing to /email. Getting there means changing collection and folder, and
/// both of those close whatever message is open — so the rule below is the
/// only thing standing between "the link works" and "the link drops the user
/// in the right mailbox with nothing selected".
void main() {
  Email message({String? folderId}) {
    return Email(
      id: 'msg-1',
      collectionId: 'gmail-1',
      date: DateTime(2026, 5, 4),
      from: 'sender@example.com',
      to: const ['me@example.com'],
      subject: 'Beach trip photos',
      folderId: folderId,
      isDeleted: false,
    );
  }

  group('resolvePendingEmail', () {
    /// Feeds a sequence of folder selections through the rule the way the page
    /// does, and reports what ends up open.
    Email? runSequence(Email pending, List<String?> folderIds) {
      Email? live = pending;
      var arrived = false;
      Email? open;

      for (final folderId in folderIds) {
        final outcome = resolvePendingEmail(
          pending: live,
          hasArrived: arrived,
          folderId: folderId,
        );
        open = outcome.open;
        if (outcome.open != null) arrived = true;
        if (!outcome.keepPending) {
          live = null;
          arrived = false;
        }
      }
      return open;
    }

    test('survives the stale folder replayed on subscribe', () {
      // EmailPage.selectedFolder is static and outlives the page, so mounting
      // replays whichever folder was open last — before the deep-link's own
      // event. Treating that as the user navigating away ended the request
      // before it was served: the page reached the right collection and the
      // right folder with no message shown, which is exactly what this looked
      // like from the outside.
      final pending = message(folderId: 'Label_7');

      final open = runSequence(pending, <String?>[
        'INBOX', // stale replay from the last visit
        null, // the collection switch resetting the folder
        'Label_7', // the collection listener forwarding the target
        'Label_7', // the request publishing it as well
      ]);

      expect(open, same(pending));
    });

    test('a stale folder alone does not open anything', () {
      // Surviving the stale event must not mean acting on it.
      final outcome = resolvePendingEmail(
        pending: message(folderId: 'Label_7'),
        hasArrived: false,
        folderId: 'INBOX',
      );

      expect(outcome.open, isNull);
      expect(outcome.keepPending, isTrue);
    });

    test('once arrived, a different folder ends the request', () {
      // The other half of the same rule: after the message has been shown, a
      // foreign folder really is the user leaving.
      final pending = message(folderId: 'Label_7');

      final open = runSequence(pending, <String?>['Label_7', 'INBOX']);

      expect(open, isNull);
    });

    test('after leaving, returning to the folder does not reopen it', () {
      final pending = message(folderId: 'Label_7');

      final open = runSequence(pending, <String?>[
        'Label_7',
        'INBOX',
        'Label_7',
      ]);

      expect(open, isNull);
    });

    test('opens once the message\'s own folder is on screen', () {
      final pending = message(folderId: 'Label_7');

      final outcome = resolvePendingEmail(
        pending: pending,
        hasArrived: false,
        folderId: 'Label_7',
      );

      expect(outcome.open, same(pending));
    });

    test('stays pending through the null folder a collection switch sets', () {
      // Switching collections resets the folder before the target one is
      // known. Giving up here is the bug: the mailbox opens, the message does
      // not.
      final outcome = resolvePendingEmail(
        pending: message(folderId: 'Label_7'),
        hasArrived: false,
        folderId: null,
      );

      expect(outcome.open, isNull);
      expect(outcome.keepPending, isTrue);
    });

    test('a repeat of the target folder keeps the message open', () {
      // The target folder is published twice on the way in — the collection
      // switch forwards it and the request publishes it — so a rule that
      // consumed the request on arrival opened the message on the first event
      // and closed it on the second.
      final pending = message(folderId: 'Label_7');

      final open = runSequence(pending, <String?>['Label_7', 'Label_7']);

      expect(open, same(pending), reason: 'the duplicate is a no-op, not a toggle');
    });

    test('the cross-collection sequence ends with the message open', () {
      // What the page publishes when the link crosses collections: reset to
      // no folder, then the target folder, then the target folder again from
      // the request itself.
      final pending = message(folderId: 'Label_7');

      final open = runSequence(pending, <String?>[null, 'Label_7', 'Label_7']);

      expect(open, same(pending));
    });

    test('opens a message that belongs to no folder at all', () {
      // PST imports and archives that predate folder capture leave folder_id
      // null; those attachments still have to link somewhere.
      final pending = message();

      expect(
        resolvePendingEmail(
          pending: pending,
          hasArrived: false,
          folderId: null,
        ).open,
        same(pending),
      );
    });

    test('an ordinary folder click closes the open message', () {
      // No deep-link in flight — the normal behaviour has to survive.
      final outcome = resolvePendingEmail(
        pending: null,
        hasArrived: false,
        folderId: 'INBOX',
      );

      expect(outcome.open, isNull);
      expect(outcome.keepPending, isFalse);
    });
  });

  group('foldersBelongTo', () {
    EmailFolder folder(String id, String collectionId) {
      return EmailFolder(
        id: id,
        collectionId: collectionId,
        name: id,
        type: 'user',
        messagesTotal: 1,
        messagesUnread: 0,
      );
    }

    test('accepts a list describing the collection on screen', () {
      expect(
        foldersBelongTo([folder('INBOX', 'gmail-1')], 'gmail-1'),
        isTrue,
      );
    });

    test('rejects the previous collection\'s folders', () {
      // The bug this guards: opening a message in a second archive switched
      // the collection, then Gmail's folder list — still in flight on the
      // shared service sink — auto-selected Gmail's INBOX. The message query
      // filters on collection *and* folder, so the archive rendered with no
      // messages at all and the message that was just opened was closed.
      expect(
        foldersBelongTo([folder('INBOX', 'gmail-1')], 'pst-archive-1998'),
        isFalse,
      );
    });

    test('rejects an empty list', () {
      // Nothing to select from, and consuming the auto-select flag on it
      // would mean the real list never gets one.
      expect(foldersBelongTo([], 'gmail-1'), isFalse);
    });

    test('rejects folders when no collection is on screen yet', () {
      expect(foldersBelongTo([folder('INBOX', 'gmail-1')], null), isFalse);
    });
  });
}
