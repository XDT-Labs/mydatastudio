import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/yahoo_idle_view.dart';

void main() {
  group('YahooIdleView', () {
    late GlobalKey<FormState> formKey;
    late TextEditingController email;
    late TextEditingController appPassword;

    setUp(() {
      formKey = GlobalKey<FormState>();
      email = TextEditingController();
      appPassword = TextEditingController();
    });

    tearDown(() {
      email.dispose();
      appPassword.dispose();
    });

    testWidgets('shows Connect Yahoo Mail heading', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: YahooIdleView(
              formKey: formKey,
              emailController: email,
              appPasswordController: appPassword,
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
              formKey: formKey,
              emailController: email,
              appPasswordController: appPassword,
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
              formKey: formKey,
              emailController: email,
              appPasswordController: appPassword,
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
              formKey: formKey,
              emailController: email,
              appPasswordController: appPassword,
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
