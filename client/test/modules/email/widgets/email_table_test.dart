import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  /// The heading checkbox is first, so row N's is at N + 1.
  Finder checkboxForRow(int index) => find.byType(Checkbox).at(index + 1);

  /// Runs [action] with shift genuinely down, so the widget sees what
  /// `HardwareKeyboard.instance.isShiftPressed` reports in the real app.
  Future<void> withShiftHeld(
    WidgetTester tester,
    Future<void> Function() action,
  ) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await action();
    await tester.pumpAndSettle();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }

  group('EmailTable selection', () {
    testWidgets('a row checkbox selects the row without opening it', (
      tester,
    ) async {
      final emails = [buildEmail('1', 'First'), buildEmail('2', 'Second')];
      final recorder = await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(0));
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

    testWidgets('shift-clicking a checkbox selects the range from the last one', (
      tester,
    ) async {
      // Marking a run of messages for deletion, one checkbox at a time, is the
      // thing this replaces.
      final emails = List.generate(6, (i) => buildEmail('$i', 'Message $i'));
      final recorder = await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(1));
      await tester.pumpAndSettle();

      await withShiftHeld(tester, () => tester.tap(checkboxForRow(4)));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, true, true, true, true, false],
      );
      expect(recorder.opened, isEmpty);
    });

    testWidgets('shift-clicking upwards selects the range too', (tester) async {
      // The anchor is one end of the range, not the top of it.
      final emails = List.generate(6, (i) => buildEmail('$i', 'Message $i'));
      await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(4));
      await tester.pumpAndSettle();

      await withShiftHeld(tester, () => tester.tap(checkboxForRow(1)));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, true, true, true, true, false],
      );
    });

    testWidgets('shift-clicking a checked row clears the range', (
      tester,
    ) async {
      // The range takes whatever value the clicked row is taking, so the same
      // gesture undoes an over-wide selection.
      final emails = List.generate(5, (i) => buildEmail('$i', 'Message $i'));
      await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(0));
      await tester.pumpAndSettle();
      await withShiftHeld(tester, () => tester.tap(checkboxForRow(4)));
      expect(emails.every((e) => e.isSelected == true), isTrue);

      await withShiftHeld(tester, () => tester.tap(checkboxForRow(3)));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, false, false, false, true],
        reason: 'rows 0-3 clear; row 4 was outside the range',
      );
    });

    testWidgets('shift-clicking with nothing checked selects one row', (
      tester,
    ) async {
      // No anchor means nothing to extend from; it must not select everything
      // up to row 0.
      final emails = List.generate(4, (i) => buildEmail('$i', 'Message $i'));
      await pumpTable(tester, emails);

      await withShiftHeld(tester, () => tester.tap(checkboxForRow(2)));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, false, true, false],
      );
    });

    testWidgets('shift-clicking row content extends instead of opening', (
      tester,
    ) async {
      // The checkbox is a small target for a two-handed gesture, and holding
      // shift is never a request to read a message.
      final emails = List.generate(5, (i) => buildEmail('$i', 'Message $i'));
      final recorder = await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(1));
      await tester.pumpAndSettle();

      await withShiftHeld(tester, () => tester.tap(find.text('Message 3')));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, true, true, true, false],
      );
      expect(
        recorder.opened,
        isEmpty,
        reason: 'shift-click must not open the message',
      );
    });

    testWidgets('select-all clears the anchor', (tester) async {
      // Otherwise a shift-click afterwards would extend from a row the user
      // last touched several actions ago.
      final emails = List.generate(5, (i) => buildEmail('$i', 'Message $i'));
      await pumpTable(tester, emails);

      await tester.tap(checkboxForRow(0));
      await tester.pumpAndSettle();
      // Select all, then clear it again, leaving every row unchecked.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      await withShiftHeld(tester, () => tester.tap(checkboxForRow(3)));

      expect(
        emails.map((e) => e.isSelected ?? false),
        [false, false, false, true, false],
      );
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
