import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/gmail_loading_view.dart';

void main() {
  group('GmailLoadingView', () {
    testWidgets('shows progress indicator', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GmailLoadingView())),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('shows connecting text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: GmailLoadingView())),
      );

      expect(find.textContaining('onnecting'), findsOneWidget);
    });
  });
}
