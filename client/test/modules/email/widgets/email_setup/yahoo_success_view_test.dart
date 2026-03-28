import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_success_view.dart';

void main() {
  group('YahooSuccessView', () {
    testWidgets('shows connected heading', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: YahooSuccessView(connectedEmail: null),
          ),
        ),
      );

      expect(find.textContaining('Connected'), findsOneWidget);
    });

    testWidgets('shows email when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: YahooSuccessView(connectedEmail: 'me@yahoo.com'),
          ),
        ),
      );

      expect(find.text('me@yahoo.com'), findsOneWidget);
    });

    testWidgets('hides email when null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: YahooSuccessView(connectedEmail: null),
          ),
        ),
      );

      expect(find.text('me@yahoo.com'), findsNothing);
    });
  });
}
