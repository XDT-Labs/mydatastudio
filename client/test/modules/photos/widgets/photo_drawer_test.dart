import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/photo_drawer.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/source_group_header.dart';
import 'package:mydatastudio/services/get_collections_service.dart';

import '../../../helpers/file_fixture.dart';

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

/// Taps a group's own chevron. Group headers start collapsed by default, and
/// other DrawerSections (Sources, Albums) also render expand_less/more icons,
/// so the finder is scoped to this group's own header row.
Future<void> _expandGroup(WidgetTester tester, String groupLabel) async {
  final headerFinder = find.ancestor(
    of: find.text(groupLabel),
    matching: find.byType(SourceGroupHeader),
  );
  final chevronFinder = find.descendant(
    of: headerFinder,
    matching: find.byIcon(Icons.expand_more),
  );
  await tester.tap(chevronFinder);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    ViewStateService.instance.setActiveNav('all');
    ViewStateService.instance.updateFilter(const PhotoFilter());
    GetCollectionsService.instance.reset();
    PhotosService.instance.collectionPhotoCounts.add({});
  });

  group('PhotoDrawer Widget Tests', () {
    testWidgets('renders all sections (Library, Sources, Albums, Tags, Locations)', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      // Section 1: Library items
      expect(find.text('All Photos'), findsOneWidget);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.text('Videos'), findsOneWidget);

      // Section 2: Sources (empty state — no collections seeded)
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('No sources'), findsOneWidget);

      // Section 3: Albums
      expect(find.text('Albums'), findsOneWidget);

      // Section 4: Tags
      expect(find.text('Tags'), findsOneWidget);

      // Section 5: Locations
      expect(find.text('Locations'), findsOneWidget);
    });

    testWidgets('tapping library nav items updates active state in ViewStateService', (tester) async {
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
    });

    testWidgets('groups collections by source and shows one header per group', (tester) async {
      final localCol = makeTestCollection(
        name: 'My Computer',
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
      );
      final gdriveCol = makeTestCollection(
        name: 'Drive (user@example.com)',
        type: 'file',
        scanner: AppConstants.scannerFileGDrive,
      );
      final gmailCol = makeTestCollection(
        name: 'Gmail (person@example.com)',
        type: 'email',
        scanner: AppConstants.scannerEmailGmail,
      );

      GetCollectionsService.instance.sink.add([localCol, gdriveCol, gmailCol]);

      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      expect(find.text('Local Folders'), findsOneWidget);
      expect(find.text('Google Drive'), findsOneWidget);
      expect(find.text('Gmail'), findsOneWidget);

      // Groups start collapsed — their collections aren't shown yet.
      expect(find.text('My Computer'), findsNothing);
      expect(find.text('user@example.com'), findsNothing);
      expect(find.text('person@example.com'), findsNothing);

      // Expanding a group reveals its collection(s).
      await _expandGroup(tester, 'Local Folders');
      expect(find.text('My Computer'), findsOneWidget);
    });

    testWidgets('tapping a collection filters to just that collection', (tester) async {
      final localCol = makeTestCollection(
        name: 'My Computer',
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
      );
      final gdriveCol = makeTestCollection(
        name: 'Drive (user@example.com)',
        type: 'file',
        scanner: AppConstants.scannerFileGDrive,
      );
      GetCollectionsService.instance.sink.add([localCol, gdriveCol]);

      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();
      await _expandGroup(tester, 'Local Folders');

      await tester.tap(find.text('My Computer'));
      await tester.pumpAndSettle();

      expect(
        ViewStateService.instance.activeFilter.value.collectionId,
        equals(localCol.id),
      );
      expect(
        ViewStateService.instance.activeNav.value,
        equals('source_collection_${localCol.id}'),
      );

      // Tapping the same collection again clears the filter.
      await tester.tap(find.text('My Computer'));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.activeFilter.value.collectionId, isNull);
      expect(ViewStateService.instance.activeNav.value, equals('all'));
    });

    testWidgets('tapping a source group header filters to every collection in the group', (tester) async {
      final gmailCol1 = makeTestCollection(
        name: 'Gmail (one@example.com)',
        type: 'email',
        scanner: AppConstants.scannerEmailGmail,
      );
      final gmailCol2 = makeTestCollection(
        name: 'Gmail (two@example.com)',
        type: 'email',
        scanner: AppConstants.scannerEmailGmail,
      );
      GetCollectionsService.instance.sink.add([gmailCol1, gmailCol2]);

      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Gmail'));
      await tester.pumpAndSettle();

      final filter = ViewStateService.instance.activeFilter.value;
      expect(filter.collectionId, isNull);
      expect(
        filter.collectionIds?.toSet(),
        equals({gmailCol1.id, gmailCol2.id}),
      );
      expect(
        ViewStateService.instance.activeNav.value,
        equals('source_group_gmail'),
      );

      // Tapping the group header again clears the filter.
      await tester.tap(find.text('Gmail'));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.activeFilter.value.collectionIds, isNull);
      expect(ViewStateService.instance.activeNav.value, equals('all'));
    });

    testWidgets('source groups start collapsed, and the chevron toggles visibility without changing the filter', (tester) async {
      final localCol = makeTestCollection(
        name: 'My Computer',
        type: 'file',
        scanner: AppConstants.scannerFileLocal,
      );
      GetCollectionsService.instance.sink.add([localCol]);

      await tester.pumpWidget(createTestApp(const PhotoDrawer()));
      await tester.pumpAndSettle();

      // Collapsed by default.
      expect(find.text('My Computer'), findsNothing);

      await _expandGroup(tester, 'Local Folders');
      expect(find.text('My Computer'), findsOneWidget);
      expect(ViewStateService.instance.activeFilter.value.collectionId, isNull);

      // The chevron is the trailing expand/collapse icon within this group's
      // own header row — other DrawerSections (Sources, Albums) also render
      // expand_less icons, so scope the finder to the Local Folders header.
      final headerFinder = find.ancestor(
        of: find.text('Local Folders'),
        matching: find.byType(SourceGroupHeader),
      );
      final chevronFinder = find.descendant(
        of: headerFinder,
        matching: find.byIcon(Icons.expand_less),
      );
      await tester.tap(chevronFinder);
      await tester.pumpAndSettle();

      expect(find.text('My Computer'), findsNothing);
      expect(ViewStateService.instance.activeFilter.value.collectionId, isNull);
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
