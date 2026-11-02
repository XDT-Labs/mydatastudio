import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/imap_error_view.dart';

void main() {
  group('ImapErrorView', () {
    testWidgets('shows Setup Failed heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImapErrorView(errorMessage: null, onRetry: () {}),
          ),
        ),
      );

      expect(find.textContaining('Failed'), findsOneWidget);
    });

    testWidgets('shows error message when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImapErrorView(
              errorMessage: 'IMAP auth failed',
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('IMAP auth failed'), findsOneWidget);
    });

    testWidgets('hides error message when null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImapErrorView(errorMessage: null, onRetry: () {}),
          ),
        ),
      );

      expect(find.text('IMAP auth failed'), findsNothing);
    });

    testWidgets('retry button calls onRetry', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImapErrorView(
              errorMessage: null,
              onRetry: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(ElevatedButton));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
