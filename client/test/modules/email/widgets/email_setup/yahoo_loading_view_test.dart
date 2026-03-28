import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_loading_view.dart';

void main() {
  group('YahooLoadingView', () {
    testWidgets('shows progress indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: YahooLoadingView()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows verifying text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: YahooLoadingView()),
        ),
      );

      expect(find.textContaining('erifying'), findsOneWidget);
    });
  });
}
