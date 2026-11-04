import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email_delete_policy.dart';
import 'package:mydatastudio/modules/email/widgets/email_account_settings_dialog.dart';

Collection _col(String scanner, {EmailDeletePolicy? policy}) => Collection(
      id: 'c1',
      name: 'Work',
      path: '',
      type: 'email',
      scanner: scanner,
      scanStatus: 'idle',
      needsReAuth: false,
      emailDeletePolicy: policy ?? EmailDeletePolicy.keep,
    );

Future<void> _open(
  WidgetTester tester,
  Collection col,
  Future<void> Function(Collection) onSave,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showEmailAccountSettingsDialog(
            context,
            collection: col,
            onSave: onSave,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('supportsEmailDeletePolicy', () {
    test('true only for IMAP-backed scanners (PST imports see no deletions)', () {
      expect(supportsEmailDeletePolicy(AppConstants.scannerEmailImap), isTrue);
      expect(supportsEmailDeletePolicy(AppConstants.scannerEmailYahoo), isTrue);
      expect(supportsEmailDeletePolicy(AppConstants.scannerEmailOutlook), isTrue);
      expect(supportsEmailDeletePolicy(AppConstants.scannerEmailOutlookPst), isFalse);
    });
  });

  group('EmailAccountSettingsDialog', () {
    testWidgets('shows keep selected by default', (tester) async {
      await _open(tester, _col(AppConstants.scannerEmailImap), (_) async {});
      final group = tester.widget<RadioGroup<EmailDeletePolicy>>(
          find.byType(RadioGroup<EmailDeletePolicy>));
      expect(group.groupValue, EmailDeletePolicy.keep);
      expect(find.textContaining('permanent'), findsOneWidget);
    });

    testWidgets('shows the current stored value', (tester) async {
      await _open(
          tester,
          _col(AppConstants.scannerEmailImap,
              policy: EmailDeletePolicy.markDeleted),
          (_) async {});
      final group = tester.widget<RadioGroup<EmailDeletePolicy>>(
          find.byType(RadioGroup<EmailDeletePolicy>));
      expect(group.groupValue, EmailDeletePolicy.markDeleted);
    });

    testWidgets('saving a non-destructive choice persists it', (tester) async {
      Collection? saved;
      await _open(tester, _col(AppConstants.scannerEmailImap),
          (c) async => saved = c);
      await tester.tap(find.text('Hide in this app'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved?.emailDeletePolicy, EmailDeletePolicy.markDeleted);
      expect(find.byType(EmailAccountSettingsDialog), findsNothing);
    });

    testWidgets('remove asks for confirmation; cancel leaves it unchanged',
        (tester) async {
      Collection? saved;
      await _open(tester, _col(AppConstants.scannerEmailImap),
          (c) async => saved = c);
      await tester.tap(find.text('Delete from this app'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Permanently delete local copies?'), findsOneWidget);
      expect(saved, isNull);

      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.byType(EmailAccountSettingsDialog), findsOneWidget);
    });

    testWidgets('confirming remove persists it', (tester) async {
      Collection? saved;
      await _open(tester, _col(AppConstants.scannerEmailImap),
          (c) async => saved = c);
      await tester.tap(find.text('Delete from this app'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete locally'));
      await tester.pumpAndSettle();
      expect(saved?.emailDeletePolicy, EmailDeletePolicy.remove);
    });

    testWidgets('a failed save leaves the in-memory policy unchanged',
        (tester) async {
      // The dialog edits the drawer's live Collection; if the write fails it
      // must not show a policy the database doesn't have.
      final col = _col(AppConstants.scannerEmailImap);
      await _open(tester, col, (_) async => throw StateError('db locked'));
      await tester.tap(find.text('Hide in this app'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Couldn't save"), findsOneWidget);
      expect(col.emailDeletePolicy, EmailDeletePolicy.keep);
      expect(find.byType(EmailAccountSettingsDialog), findsOneWidget);
    });

    testWidgets('saving unchanged remove does not re-confirm', (tester) async {
      Collection? saved;
      await _open(
          tester,
          _col(AppConstants.scannerEmailImap, policy: EmailDeletePolicy.remove),
          (c) async => saved = c);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Permanently delete local copies?'), findsNothing);
      expect(saved?.emailDeletePolicy, EmailDeletePolicy.remove);
    });
  });
}
