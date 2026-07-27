import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/email/notifications/email_selected_notification.dart';
import 'package:mydatastudio/modules/email/notifications/email_selection_changed_notification.dart';
import 'package:mydatastudio/modules/email/widgets/email_table.dart';

/// Selecting a row and opening a row are different intents, and the table has
/// to keep them apart: a checkbox marks a message for a bulk delete, a tap on
/// the row reads it. They shared one notification once, which made ticking any
/// checkbox — including select-all — open a message the user never asked for.
void main() {
  Email buildEmail(String id, String subject) {
    return Email(
      id: id,
      collectionId: 'collection-1',
      date: DateTime(2024, 1, 1),
      from: 'Someone <someone@example.com>',
      to: const ['me@example.com'],
      subject: subject,
      isDeleted: false,
    );
  }

  /// Pumps the table and records which notifications it emits.
  Future<_Recorder> pumpTable(WidgetTester tester, List<Email> emails) async {
    final recorder = _Recorder();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotificationListener<Notification>(
            onNotification: (n) {
              if (n is EmailSelectedNotification) {
                recorder.opened.add(n.email);
                return true;
              }
              if (n is EmailSelectionChangedNotification) {
                recorder.selectionChanges++;
                return true;
              }
              return false;
            },
            child: SizedBox(
              width: 900,
              height: 600,
              child: EmailTable(emails: emails),
            ),
          ),
        ),
      ),
    );

    return recorder;
  }

  group('EmailTable selection', () {
    testWidgets('a row checkbox selects the row without opening it', (
      tester,
    ) async {
      final emails = [buildEmail('1', 'First'), buildEmail('2', 'Second')];
      final recorder = await pumpTable(tester, emails);

      // The heading checkbox is first; the one after it belongs to row 1.
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();

      expect(emails[0].isSelected, isTrue);
      // Null until touched — an untouched row must stay that way.
      expect(emails[1].isSelected ?? false, isFalse);
      expect(
        recorder.opened,
        isEmpty,
        reason: 'checking a row must not open the message',
      );
      expect(recorder.selectionChanges, 1);
    });

    testWidgets('select-all checks every row without opening any', (
      tester,
    ) async {
      final emails = [
        buildEmail('1', 'First'),
        buildEmail('2', 'Second'),
        buildEmail('3', 'Third'),
      ];
      final recorder = await pumpTable(tester, emails);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(emails.every((e) => e.isSelected == true), isTrue);
      expect(
        recorder.opened,
        isEmpty,
        reason: 'select-all must not open the first message',
      );
      expect(recorder.selectionChanges, 1);
    });

    testWidgets('select-all a second time clears every row', (tester) async {
      final emails = [buildEmail('1', 'First'), buildEmail('2', 'Second')];
      final recorder = await pumpTable(tester, emails);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      expect(emails.every((e) => e.isSelected == false), isTrue);
      expect(recorder.opened, isEmpty);
      expect(recorder.selectionChanges, 2);
    });

    testWidgets('tapping a row cell opens that message', (tester) async {
      final emails = [buildEmail('1', 'First'), buildEmail('2', 'Second')];
      final recorder = await pumpTable(tester, emails);

      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();

      expect(recorder.opened.map((e) => e.id), ['2']);
      expect(
        emails.any((e) => e.isSelected == true),
        isFalse,
        reason: 'opening a message is not the same as checking it',
      );
    });
  });
}

/// Mutable so assertions read the counts as they stand *after* the taps — a
/// record would have snapshotted them at pump time.
class _Recorder {
  final List<Email> opened = [];
  int selectionChanges = 0;
}
