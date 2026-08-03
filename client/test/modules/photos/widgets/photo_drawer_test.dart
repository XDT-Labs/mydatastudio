import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/photo_drawer.dart';

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: darkColorScheme,
    ),
    home: Scaffold(
      body: SizedBox(
        height: 1000,
        child: child,
      ),
    ),
  );
}

void main() {
  setUp(() {
    ViewStateService.instance.setActiveNav('all');
    ViewStateService.instance.updateFilter(const PhotoFilter());
  });

  group('PhotoDrawer Widget Tests', () {
    testWidgets('renders all sections (Library, Sources, Albums, Tags, Locations)', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      // Section 1: Library items
      expect(find.text('All Photos'), findsOneWidget);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Videos'), findsOneWidget);

      // Section 2: Sources
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('Local Folders'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Email Attachments'), findsOneWidget);

      // Section 3: Albums
      expect(find.text('Albums'), findsOneWidget);

      // Section 4: Tags
      expect(find.text('Tags'), findsOneWidget);

      // Section 5: Locations
      expect(find.text('Locations'), findsOneWidget);
    });

    testWidgets('tapping nav items updates active state in ViewStateService', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      // Tap Favorites
      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.activeNav.value, equals('favorites'));
      expect(ViewStateService.instance.activeFilter.value.onlyFavorites, isTrue);

      // Tap Videos
      await tester.tap(find.text('Videos'));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.activeNav.value, equals('videos'));
      expect(ViewStateService.instance.activeFilter.value.mediaType, equals('video'));

      // Tap Local Folders
      await tester.tap(find.text('Local Folders'));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.activeNav.value, equals('source_local'));
      expect(ViewStateService.instance.activeFilter.value.source, equals('local'));
    });

    testWidgets('clear filters button appears when filter active and clears on tap', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      // Initially no filter is active, so Clear Filters is not visible
      expect(find.text('Clear Filters'), findsNothing);

      // Set filter to Favorites by tapping Favorites
      await tester.tap(find.text('Favorites'));
      await tester.pumpAndSettle();

      // Clear Filters button should now be visible
      final clearButtonFinder = find.text('Clear Filters');
      expect(clearButtonFinder, findsOneWidget);

      // Scroll to button and tap
      await tester.ensureVisible(clearButtonFinder);
      await tester.pumpAndSettle();
      await tester.tap(clearButtonFinder);
      await tester.pumpAndSettle();

      // Filter should be reset
      expect(find.text('Clear Filters'), findsNothing);
      expect(ViewStateService.instance.activeNav.value, equals('all'));
      expect(ViewStateService.instance.activeFilter.value.onlyFavorites, isFalse);
    });
  });
}
