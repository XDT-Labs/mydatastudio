import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/photos_toolbar.dart';

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
      // Delete removed from the batch toolbar — deleting is still available
      // via the keyboard shortcut and the per-item Similar-images tab.
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // Deselect restores normal mode
      await tester.tap(find.text('Deselect'));
      await tester.pumpAndSettle();

      expect(find.text('Search photos...'), findsOneWidget);
      expect(find.text('2 selected'), findsNothing);
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
