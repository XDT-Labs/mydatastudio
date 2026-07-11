import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/pages/settings.dart';
import 'package:mydatastudio/pages/settings_drawer.dart';

void main() {
  late Directory tempDir;
  late DatabaseManager databaseManager;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('settings_test_');

    const MethodChannel channel = MethodChannel(
      'plugins.flutter.io/path_provider',
    );
    // ignore: deprecated_member_use
    channel.setMockMethodCallHandler((MethodCall methodCall) async {
      return tempDir.path;
    });

    databaseManager = DatabaseManager.instance;
    await databaseManager.initializeDatabase();
  });

  tearDown(() async {
    databaseManager.dispose();
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Widget buildTestWidget(GoRouter router) {
    return MaterialApp.router(
      routerConfig: router,
    );
  }

  group('SettingsDrawer tests', () {
    testWidgets('renders Collections category and expands Providers under it when route is /settings', (tester) async {
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => const Scaffold(
              drawer: Drawer(child: SettingsDrawer()),
              body: Text('Settings Body'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(router));
      await tester.pumpAndSettle();

      // Open the drawer
      final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Verify "Collections" header is present
      expect(find.text('Collections'), findsOneWidget);
      // Verify "Providers" sub-item is present and visible (expanded by default)
      expect(find.text('Providers'), findsOneWidget);

      // Tap on "Collections" to collapse it
      await tester.tap(find.text('Collections'));
      await tester.pumpAndSettle();

      // Verify "Providers" is no longer visible
      expect(find.text('Providers'), findsNothing);
    });

    testWidgets('renders AI Chat category and expands Models/Skills under it when route is /settings/aichat-models', (tester) async {
      final router = GoRouter(
        initialLocation: '/settings/aichat-models',
        routes: [
          GoRoute(
            path: '/settings/aichat-models',
            builder: (context, state) => const Scaffold(
              drawer: Drawer(child: SettingsDrawer()),
              body: Text('Models Body'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(router));
      await tester.pumpAndSettle();

      // Open the drawer
      final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));
      scaffoldState.openDrawer();
      await tester.pumpAndSettle();

      // Verify "AI Chat" header is present
      expect(find.text('AI Chat'), findsOneWidget);
      // Verify "Models" and "Skills" sub-items are present
      expect(find.text('Models'), findsOneWidget);
      expect(find.text('Skills'), findsOneWidget);
      // Verify "Providers" is not visible by default since the route starts with /settings/aichat
      expect(find.text('Providers'), findsNothing);
    });
  });

  group('SettingsPage tests', () {
    testWidgets('renders Google provider without API Key field, and others with API Key field', (tester) async {
      tester.view.physicalSize = const Size(1600, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => const Scaffold(body: SettingsPage()),
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(router));
      // Run the async event loop to let database queries finish loading the settings page
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 1));
      });
      await tester.pumpAndSettle();

      // Google card should be present
      expect(find.text('GOOGLE'), findsOneWidget);
      // MICROSOFT/AZURE card should be present
      expect(find.text('MICROSOFT/AZURE'), findsOneWidget);

      // Google has API Key hidden, there should be 5 "API Key (Optional)" labels.
      expect(find.text('API Key (Optional)'), findsNWidgets(5));

      // Verify Google specific instructions and link are visible
      expect(
        find.text(
          'To connect to Google services, you must provide your own OAuth Client ID and Client Secret. Ensure your OAuth consent screen is configured with the following scopes:\n'
          '• https://www.googleapis.com/auth/userinfo.email\n'
          '• https://www.googleapis.com/auth/userinfo.profile\n'
          '• https://www.googleapis.com/auth/drive\n'
          '• https://www.googleapis.com/auth/user.emails.read\n'
          '• https://www.googleapis.com/auth/gmail.readonly\n\n'
          'Note: Ensure that the Google People API, Google Drive API, and Gmail API are enabled in your Google Cloud Console project.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Get Credentials from Google Cloud Console'),
        findsOneWidget,
      );

      // Verify no Save buttons are rendered
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('typing in client ID triggers database update automatically after debounce', (tester) async {
      tester.view.physicalSize = const Size(1600, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (context, state) => const Scaffold(body: SettingsPage()),
          ),
        ],
      );

      await tester.pumpWidget(buildTestWidget(router));
      await tester.runAsync(() async {
        await Future.delayed(const Duration(seconds: 1));
      });
      await tester.pumpAndSettle();

      // Find the Google Client ID text field (first TextField in the tree)
      final clientIdTextFieldFinder = find.byType(TextField).first;

      // Enter some text
      await tester.enterText(clientIdTextFieldFinder, 'my-new-google-client-id');
      await tester.pump();

      // The database should not be updated immediately because of the 600ms debounce
      await tester.runAsync(() async {
        final db = DatabaseManager.instance.database!;
        var rows = await db.select(
          "SELECT * FROM providers WHERE service = 'google'",
        );
        expect(rows.isEmpty || rows.first['client_id'] != 'my-new-google-client-id', isTrue);
      });

      // Advance fake time to trigger the 600ms debounce timer
      await tester.pump(const Duration(milliseconds: 800));

      // Yield to the real event loop so the isolate can process the SQLite execute
      await tester.runAsync(() async {
        await Future.delayed(const Duration(milliseconds: 500));
      });

      // Pump the fake clock to process the receive port message and complete the execute future
      await tester.pump();

      // Query the database to verify the update
      await tester.runAsync(() async {
        final db = DatabaseManager.instance.database!;
        final rows = await db.select(
          "SELECT * FROM providers WHERE service = 'google'",
        );
        expect(rows.isNotEmpty, isTrue);
        expect(rows.first['client_id'], equals('my-new-google-client-id'));
      });
    });
  });
}
