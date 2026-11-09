import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/cloud_account_branding.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/google_drive_configure_view.dart';
import 'package:mydatastudio/oauth/login_providers.dart';
import 'package:mydatastudio/pages/google_oauth_setup_guide.dart';

/// Google Drive works only once the user has created their own OAuth client,
/// so the setup steps have to be right and easy to reach.
void main() {
  Future<void> pumpGuide(WidgetTester tester, {bool expanded = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GoogleOAuthSetupGuide(initiallyExpanded: expanded),
            ),
          ),
        ),
      );

  test('lists exactly the scopes Drive sign-in requests', () {
    // A scope missing from the user's consent screen makes sign-in fail; an
    // extra one asks the user for access the app never uses.
    expect(
      GoogleOAuthSetupGuide.scopes.toSet(),
      LoginProviders.googleDrive.scopes.toSet(),
    );
  });

  testWidgets('is collapsed by default', (tester) async {
    await pumpGuide(tester);
    expect(find.text('How to create your own Google OAuth client'), findsOne);
    expect(find.text('Enable the Google Drive API'), findsNothing);
  });

  testWidgets('opens when asked, with the publish step', (tester) async {
    // Publishing is the step people miss: in Testing, Google signs them out
    // of Drive every 7 days.
    await pumpGuide(tester, expanded: true);
    expect(find.text('Enable the Google Drive API'), findsOne);
    expect(find.text('Publish the app (important)'), findsOne);
    expect(find.textContaining('every 7 days'), findsOne);
  });

  group('Add Source configure view', () {
    Future<GoRouter> pumpConfigure(
      WidgetTester tester,
      CloudAccountBranding branding,
    ) async {
      tester.view.physicalSize = const Size(1000, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        initialLocation: '/files/add',
        routes: [
          GoRoute(
            path: '/files/add',
            builder:
                (_, _) => Scaffold(
                  body: GoogleDriveConfigureView(
                    branding: branding,
                    onConfigured: () {},
                  ),
                ),
          ),
          GoRoute(
            path: '/settings',
            builder:
                (context, state) => Scaffold(
                  body: TextButton(
                    onPressed: () => GoRouter.of(context).pop(),
                    child: Text('settings ${state.uri.query}'),
                  ),
                ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      return router;
    }

    testWidgets('Google Drive links to the setup steps in Settings', (
      tester,
    ) async {
      await pumpConfigure(tester, CloudAccountBranding.googleDrive);
      await tester.enterText(find.byType(TextField).first, 'typed-id');
      await tester.tap(find.byKey(const ValueKey('setup-guide-link')));
      await tester.pumpAndSettle();
      expect(find.text('settings setup=google'), findsOne);

      // Back returns to the form with what was typed, not to the home page.
      await tester.tap(find.text('settings setup=google'));
      await tester.pumpAndSettle();
      expect(find.text('typed-id'), findsOne);
    });

    testWidgets('Dropbox has no Google setup link', (tester) async {
      await pumpConfigure(tester, CloudAccountBranding.dropbox);
      expect(find.byKey(const ValueKey('setup-guide-link')), findsNothing);
    });
  });
}
