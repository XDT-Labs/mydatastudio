import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/services/get_collections_service.dart';
import 'package:mydatastudio/widgets/auth_dialog_manager.dart';

Collection _col(String oauthService, {String type = 'file'}) => Collection(
  id: 'c',
  name: 'n',
  path: 'root',
  type: type,
  scanner: 'x',
  scanStatus: 'ready',
  oauthService: oauthService,
  needsReAuth: true,
);

void main() {
  Future<void> emit(WidgetTester tester, Collection c) async {
    // Fresh service so the previous test's listener doesn't fire again.
    GetCollectionsService.instance = GetCollectionsService();
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const Scaffold()),
    );
    AuthDialogManager(key).init();
    GetCollectionsService.instance.sink.add([c]);
    await tester.pumpAndSettle();
  }

  testWidgets('Dropbox collection needing re-auth gets a Dropbox prompt', (
    tester,
  ) async {
    await emit(tester, _col('dropbox'));
    expect(find.text('Authentication Expired'), findsOneWidget);
    expect(
      find.textContaining('Your Dropbox sign-in has expired'),
      findsOneWidget,
    );
    expect(find.text('Sign in to Dropbox'), findsOneWidget);
  });

  testWidgets('OneDrive collection needing re-auth gets a OneDrive prompt', (
    tester,
  ) async {
    await emit(tester, _col('onedrive'));
    expect(
      find.textContaining('Your OneDrive sign-in has expired'),
      findsOneWidget,
    );
    expect(find.text('Sign in to OneDrive'), findsOneWidget);
  });

  testWidgets('Google Drive prompt wording is unchanged', (tester) async {
    await emit(tester, _col('google'));
    expect(
      find.textContaining(
        "Your Google OAuth token has expired or been revoked for 'Google Drive'",
      ),
      findsOneWidget,
    );
    expect(find.text('Login with Google (Google Drive)'), findsOneWidget);
  });
}
