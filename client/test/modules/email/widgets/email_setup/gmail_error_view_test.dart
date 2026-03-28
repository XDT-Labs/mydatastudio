import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_error_view.dart';

void main() {
  group('GmailErrorView', () {
    testWidgets('shows Setup Failed heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GmailErrorView(errorMessage: null, onRetry: () {}),
          ),
        ),
      );

      expect(find.textContaining('Failed'), findsOneWidget);
    });

    testWidgets('shows error message when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GmailErrorView(
              errorMessage: 'Network error',
              onRetry: () {},
            ),
          ),
        ),
      );

      expect(find.text('Network error'), findsOneWidget);
    });

    testWidgets('hides error message when null', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GmailErrorView(errorMessage: null, onRetry: () {}),
          ),
        ),
      );

      expect(find.text('Network error'), findsNothing);
    });

    testWidgets('retry button calls onRetry', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GmailErrorView(
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
