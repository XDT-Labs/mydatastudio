import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_error_view.dart';

void main() {
  group('YahooErrorView', () {
    testWidgets('shows Setup Failed heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooErrorView(errorMessage: null, onRetry: () {}),
          ),
        ),
      );

      expect(find.textContaining('Failed'), findsOneWidget);
    });

    testWidgets('shows error message when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooErrorView(
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
            body: YahooErrorView(errorMessage: null, onRetry: () {}),
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
            body: YahooErrorView(
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
