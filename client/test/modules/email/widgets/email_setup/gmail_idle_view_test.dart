import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/gmail_idle_view.dart';

void main() {
  group('GmailIdleView', () {
    testWidgets('renders connect button and calls onConnect', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GmailIdleView(onConnect: () => called = true)),
        ),
      );

      expect(find.byType(GmailSignInButton), findsOneWidget);

      await tester.tap(find.byType(GmailSignInButton));
      await tester.pump();

      expect(called, isTrue);
    });
  });

  group('GmailSignInButton', () {
    testWidgets('renders and calls onTap', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: GmailSignInButton(onTap: () => called = true)),
        ),
      );

      expect(find.byType(GmailSignInButton), findsOneWidget);

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('shows Google sign-in text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: GmailSignInButton(onTap: () {}))),
      );

      expect(find.textContaining('Google'), findsOneWidget);
    });
  });
}
