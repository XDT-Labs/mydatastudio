import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/email/widgets/email_setup/yahoo_idle_view.dart';
import 'package:reactive_forms/reactive_forms.dart';

void main() {
  group('YahooIdleView', () {
    late FormGroup form;

    setUp(() {
      form = FormGroup({
        'email': FormControl<String>(
          validators: [Validators.required, Validators.email],
        ),
        'appPassword': FormControl<String>(
          validators: [Validators.required, Validators.minLength(16)],
        ),
      });
    });

    testWidgets('shows Connect Yahoo Mail heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooIdleView(
              form: form,
              onConnect: () {},
              onLaunchSecurity: () {},
            ),
          ),
        ),
      );

      expect(find.textContaining('Yahoo Mail'), findsOneWidget);
    });

    testWidgets('shows email and app password fields', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooIdleView(
              form: form,
              onConnect: () {},
              onLaunchSecurity: () {},
            ),
          ),
        ),
      );

      expect(find.text('Email Address'), findsOneWidget);
      expect(find.text('App Password'), findsOneWidget);
    });

    testWidgets('shows setup instructions steps', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooIdleView(
              form: form,
              onConnect: () {},
              onLaunchSecurity: () {},
            ),
          ),
        ),
      );

      expect(find.text('Setup Instructions'), findsOneWidget);
      expect(find.text('1. '), findsOneWidget);
    });

    testWidgets('connect button calls onConnect', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooIdleView(
              form: form,
              onConnect: () => called = true,
              onLaunchSecurity: () {},
            ),
          ),
        ),
      );

      final btn = find.byType(ElevatedButton);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
