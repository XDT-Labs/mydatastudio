import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/app_constants.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/photos_toolbar.dart';
import 'package:mydatastudio/services/get_collections_service.dart';

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: darkColorScheme,
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  setUp(() {
    SelectionService.instance.deselectAll();
    ViewStateService.instance.setViewMode(PhotoViewMode.grid);
    ViewStateService.instance.updateFilter(const PhotoFilter());
    PhotosService.instance.sink.add([]);
  });

  group('PhotosToolbar Widget Tests', () {
    testWidgets('renders search field', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosToolbar()));

      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('Search photos...'), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('view mode buttons switch modes', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosToolbar()));

      expect(ViewStateService.instance.viewMode.value, PhotoViewMode.grid);

      // Tap list view segment icon
      await tester.tap(find.byIcon(Icons.view_list));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.viewMode.value, PhotoViewMode.list);

      // Tap map view segment icon
      await tester.tap(find.byIcon(Icons.map));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.viewMode.value, PhotoViewMode.map);
    });

    testWidgets('batch mode shows selection count and action buttons',
        (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosToolbar()));

      // Initially in normal mode
      expect(find.text('Search photos...'), findsOneWidget);
      expect(find.text('Select All'), findsNothing);

      // Toggle selection of items
      SelectionService.instance.toggle('id-1');
      SelectionService.instance.toggle('id-2');
      await tester.pumpAndSettle();

      // Batch mode UI displayed
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.text('Select All'), findsOneWidget);
      expect(find.text('Deselect'), findsOneWidget);
      expect(find.byIcon(Icons.playlist_add), findsOneWidget);
      expect(find.byIcon(Icons.download), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // Deselect restores normal mode
      await tester.tap(find.text('Deselect'));
      await tester.pumpAndSettle();

      expect(find.text('Search photos...'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
    });

    testWidgets(
        'delete button offers hide and delete, with source-aware copy',
        (tester) async {
      GetCollectionsService.instance.sink.add([
        Collection(
          id: 'col-gdrive',
          name: 'Drive',
          path: '/drive',
          type: 'file',
          scanner: AppConstants.scannerFileGDrive,
          scanStatus: 'idle',
          needsReAuth: false,
        ),
        Collection(
          id: 'col-pst',
          name: 'PST',
          path: '/pst',
          type: 'email',
          scanner: AppConstants.scannerEmailOutlookPst,
          scanStatus: 'idle',
          needsReAuth: false,
        ),
      ]);
      PhotosService.instance.sink.add([
        File(
          id: 'id-1',
          name: 'a.jpg',
          path: 'a.jpg',
          parent: '',
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: 'col-pst',
          contentType: 'image/jpeg',
          size: 1,
          isDeleted: false,
        ),
        File(
          id: 'id-2',
          name: 'b.jpg',
          path: 'b.jpg',
          parent: '',
          dateCreated: DateTime(2026, 1, 1),
          dateLastModified: DateTime(2026, 1, 1),
          collectionId: 'col-gdrive',
          contentType: 'image/jpeg',
          size: 1,
          isDeleted: false,
        ),
      ]);

      await tester.pumpWidget(createTestApp(const PhotosToolbar()));

      SelectionService.instance.toggle('id-1');
      SelectionService.instance.toggle('id-2');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // Two distinct promises, offered separately, because a single "Delete"
      // that only set a flag was the dishonesty this dialog exists to remove.
      expect(find.text('Remove 2 photos?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Hide in gallery'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Delete file'), findsOneWidget);
      expect(
        find.textContaining('stay on disk and in their source'),
        findsOneWidget,
      );

      // Sources are named the way the drawer's Sources list names them — the
      // user just picked these photos out of those buckets. A PST import shows
      // as "Outlook", not "Outlook PST", because that is one source to them.
      expect(find.textContaining('1 from Outlook'), findsOneWidget);
      expect(find.textContaining('Outlook PST'), findsNothing);
      expect(find.textContaining('1 from Google Drive'), findsOneWidget);

      // And delete says what it can actually reach per source: Drive has its
      // own trash, an email keeps its attachment whatever the app does.
      expect(
        find.textContaining('trash in Google Drive'),
        findsOneWidget,
      );
      expect(find.textContaining('email keeps its copy'), findsOneWidget);

      // Cancel closes without invoking either action.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Remove 2 photos?'), findsNothing);
    });

    testWidgets('search input has debounce', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosToolbar()));

      final searchField = find.byType(TextField);
      await tester.enterText(searchField, 'vacation');

      // Before 300ms timer completes, activeFilter is not updated yet
      expect(ViewStateService.instance.activeFilter.value.searchQuery, '');

      // Advance time by 350ms
      await tester.pump(const Duration(milliseconds: 350));

      expect(
          ViewStateService.instance.activeFilter.value.searchQuery, 'vacation');
    });
  });
}
