import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/gmail_success_view.dart';

void main() {
  group('GmailSuccessView', () {
    testWidgets('shows connected heading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GmailSuccessView(connectedEmail: null),
          ),
        ),
      );

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('shows email when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GmailSuccessView(connectedEmail: 'user@gmail.com'),
          ),
        ),
      );

      expect(find.text('user@gmail.com'), findsOneWidget);
    });

    testWidgets('hides email when null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GmailSuccessView(connectedEmail: null),
          ),
        ),
      );

      expect(find.text('user@gmail.com'), findsNothing);
    });
  });
}
