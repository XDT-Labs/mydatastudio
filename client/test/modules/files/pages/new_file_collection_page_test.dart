import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/modules/files/pages/new_file_collection_page.dart';

void main() {
  group('NewFileCollectionPage Widget Tests', () {
    Widget buildPage(GoRouter router) {
      return MaterialApp.router(
        routerConfig: router,
        theme: ThemeData(brightness: Brightness.light),
      );
    }

    testWidgets('renders TabBar with correct tab texts and icons', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/files/add',
        routes: [
          GoRoute(
            path: '/files/add',
            builder:
                (context, state) =>
                    const Scaffold(body: NewFileCollectionPage()),
          ),
        ],
      );

      await tester.pumpWidget(buildPage(router));
      await tester.pumpAndSettle();

      // Check that the tabs exist
      expect(find.text('Local Files'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Dropbox'), findsOneWidget);

      // Verify the TabBar contains tabs with correct icons
      final localFilesTabFinder = find.descendant(
        of: find.byType(Tab),
        matching: find.byIcon(Icons.folder),
      );
      expect(localFilesTabFinder, findsOneWidget);

      final cloudTabsFinder = find.descendant(
        of: find.byType(Tab),
        matching: find.byIcon(Icons.cloud),
      );
      // Both Google Drive and Dropbox use Icons.cloud, so expect 2 matches
      expect(cloudTabsFinder, findsNWidgets(2));
    });
  });
}
