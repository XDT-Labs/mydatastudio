import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider.dart';
import 'package:mydatastudio/modules/email/services/imap/email_provider_registry.dart';
import 'package:mydatastudio/modules/email/services/imap/imap_connection_config.dart';
import 'package:mydatastudio/modules/email/services/setup/imap_connection_tester.dart';
import 'package:mydatastudio/modules/email/widgets/email_setup/email_account_setup_tab.dart';

class _FakeTester implements ImapConnectionTester {
  _FakeTester(this.result);
  ImapConnectionResult result;
  final List<ImapConnectionRequest> requests = [];

  @override
  Future<ImapConnectionResult> test(ImapConnectionRequest request) async {
    requests.add(request);
    return result;
  }
}

void main() {
  late _FakeTester tester0;
  late List<Collection> created;

  Future<void> pumpTab(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmailAccountSetupTab(
            connectionTester: tester0,
            appDataDirectory: () => '/data',
            onAccountCreated: (c) async => created.add(c),
            onDone: (_) {},
            oauthBuilder: (context, provider) => Text('oauth-${provider.id}'),
            onOpenUrl: (_) async {},
            successDelay: Duration.zero,
          ),
        ),
      ),
    );
  }

  setUp(() {
    tester0 = _FakeTester(ImapConnectionResult.success());
    created = [];
  });

  Future<void> enterEmail(WidgetTester tester, String email) async {
    await tester.enterText(find.byKey(const Key('email-field')), email);
    await tester.pump();
  }

  testWidgets('detects Yahoo from the address and asks for an app password', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@yahoo.com');

    expect(find.text('Yahoo Mail'), findsWidgets);
    expect(find.byKey(const Key('password-field')), findsOneWidget);
    expect(find.text('App Password'), findsOneWidget);
    expect(find.byKey(const Key('host-field')), findsNothing);
  });

  testWidgets('shows the detected provider\'s setup steps', (tester) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@icloud.com');

    expect(find.text('Setup Instructions'), findsOneWidget);
    for (final step in EmailProviderRegistry.icloud.setupSteps) {
      expect(find.text(step), findsOneWidget);
    }
  });

  testWidgets('a refused iCloud login shows the revoked-password hint', (
    tester,
  ) async {
    tester0.result = ImapConnectionResult.failure(
      ImapConnectionFailure.badCredentials,
    );
    await pumpTab(tester);
    await enterEmail(tester, 'me@icloud.com');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(
      find.text(EmailProviderRegistry.icloud.authFailureHint!),
      findsOneWidget,
    );
  });

  testWidgets('an unreachable server does not show the auth hint', (
    tester,
  ) async {
    tester0.result = ImapConnectionResult.failure(
      ImapConnectionFailure.unreachable,
    );
    await pumpTab(tester);
    await enterEmail(tester, 'me@icloud.com');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-failure-hint')), findsNothing);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('region picker appears only for Zoho', (tester) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@yahoo.com');
    expect(find.byKey(const Key('region-dropdown')), findsNothing);

    await enterEmail(tester, 'me@zoho.com');
    expect(find.byKey(const Key('region-dropdown')), findsOneWidget);
  });

  testWidgets('Zoho region is tested against and persisted in settings', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@zohomail.eu');
    await tester.tap(find.byKey(const Key('region-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Europe').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(tester0.requests.single.host, 'imap.zoho.eu');
    final c = created.single;
    expect(c.emailProviderId, 'zoho');
    final settings = ImapSettings.fromJsonString(c.imapSettings!);
    expect(settings.host, 'imap.zoho.eu');
    // The scanner resolves the same host from the saved collection.
    expect(ImapConnectionConfig.fromCollection(c).host, 'imap.zoho.eu');
  });

  testWidgets('Zoho defaults to the US host when no region is picked', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@zoho.com');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(tester0.requests.single.host, 'imap.zoho.com');
    expect(
      ImapSettings.fromJsonString(created.single.imapSettings!).host,
      'imap.zoho.com',
    );
  });

  testWidgets('unknown domain falls back to Other with server fields', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@example.org');

    expect(find.byKey(const Key('host-field')), findsOneWidget);
    expect(find.byKey(const Key('port-field')), findsOneWidget);
    expect(find.byKey(const Key('security-dropdown')), findsOneWidget);
    expect(find.byKey(const Key('username-field')), findsOneWidget);
  });

  testWidgets('provider can be overridden from the dropdown', (tester) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@example.org');

    await tester.tap(find.byKey(const Key('provider-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fastmail').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('host-field')), findsNothing);
    expect(find.text('App Password'), findsOneWidget);

    // Typing again must not clobber the user's explicit choice.
    await enterEmail(tester, 'me@example.com');
    expect(find.text('App Password'), findsOneWidget);
  });

  testWidgets('oauth providers hand off to the oauth flow', (tester) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@outlook.com');

    expect(find.byKey(const Key('password-field')), findsNothing);
    await tester.tap(find.byKey(const Key('continue-oauth-button')));
    await tester.pumpAndSettle();

    expect(find.text('oauth-outlook'), findsOneWidget);
  });

  testWidgets('failed connection test shows the error and saves nothing', (
    tester,
  ) async {
    tester0.result = ImapConnectionResult.failure(
      ImapConnectionFailure.badCredentials,
    );
    await pumpTab(tester);
    await enterEmail(tester, 'me@yahoo.com');
    await tester.enterText(
      find.byKey(const Key('password-field')),
      'abcdabcdabcdabcd',
    );
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(tester0.requests, hasLength(1));
    expect(find.textContaining('password'), findsWidgets);
    expect(find.text('Try Again'), findsOneWidget);
    expect(created, isEmpty);

    // Retry returns to the form with the entered values intact.
    await tester.tap(find.text('Try Again'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('email-field')), findsOneWidget);
  });

  testWidgets('success creates an email.imap collection for Yahoo', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@yahoo.com');
    await tester.enterText(
      find.byKey(const Key('password-field')),
      'abcdabcdabcdabcd',
    );
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    final c = created.single;
    expect(c.scanner, AppConstants.scannerEmailImap);
    expect(c.emailProviderId, 'yahoo');
    expect(c.imapSettings, isNull);
    expect(c.userId, 'me@yahoo.com');
    expect(c.accessToken, 'abcdabcdabcdabcd');
    expect(c.oauthService, 'yahoo_app_password');
    expect(c.type, 'email');
    expect(tester0.requests.single.host, 'imap.mail.yahoo.com');
    expect(tester0.requests.single.port, 993);
  });

  testWidgets('success for Other stores host settings but not the password', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@example.org');
    await tester.enterText(
      find.byKey(const Key('host-field')),
      'mail.example.org',
    );
    await tester.enterText(find.byKey(const Key('port-field')), '143');
    await tester.tap(find.byKey(const Key('security-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('STARTTLS').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('username-field')), 'mike');
    await tester.enterText(find.byKey(const Key('password-field')), 'hunter2');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(created, hasLength(1));
    final c = created.single;
    expect(c.scanner, AppConstants.scannerEmailImap);
    expect(c.emailProviderId, 'other');
    expect(c.userId, 'mike');
    expect(c.accessToken, 'hunter2');
    final settings = ImapSettings.fromJsonString(c.imapSettings!);
    expect(settings.host, 'mail.example.org');
    expect(settings.port, 143);
    expect(settings.security, ImapSecurity.startTls);
    expect(settings.username, 'mike');
    expect(c.imapSettings, isNot(contains('hunter2')));
    final req = tester0.requests.single;
    expect(req.username, 'mike');
    expect(req.security, ImapSecurity.startTls);
  });

  testWidgets('username defaults to the email address for Other', (
    tester,
  ) async {
    await pumpTab(tester);
    await enterEmail(tester, 'me@example.org');
    await tester.enterText(find.byKey(const Key('host-field')), 'imap.x.org');
    await tester.enterText(find.byKey(const Key('password-field')), 'pw');
    await tester.tap(find.byKey(const Key('submit-button')));
    await tester.pumpAndSettle();

    expect(created.single.userId, 'me@example.org');
    expect(tester0.requests.single.username, 'me@example.org');
  });
}
