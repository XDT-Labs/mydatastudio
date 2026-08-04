import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/models/photo_filter.dart';
import 'package:mydatastudio/modules/photos/pages/photos_app.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/sidebar/animated_info_panel.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/photos_toolbar.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_list_view.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_map_view.dart';

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
    ViewStateService.instance.isInfoOpen.add(false);
    ViewStateService.instance.setLightboxMedia(null);
    PhotosService.instance.sink.add([]);
  });

  group('PhotosApp Page Tests', () {
    testWidgets('renders toolbar, active view, and status bar', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosApp()));
      await tester.pumpAndSettle();

      expect(find.byType(PhotosToolbar), findsOneWidget);
      expect(find.text('SPACE: View · I: Info · ESC: Close'), findsOneWidget);
      expect(find.text('0 photos, 0 videos'), findsOneWidget);
    });

    testWidgets('switches views when viewMode changes', (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosApp()));
      await tester.pumpAndSettle();

      ViewStateService.instance.setViewMode(PhotoViewMode.list);
      await tester.pumpAndSettle();

      expect(find.byType(PhotoListView), findsOneWidget);

      ViewStateService.instance.setViewMode(PhotoViewMode.map);
      await tester.pumpAndSettle();

      expect(find.byType(PhotoMapView), findsOneWidget);
    });

    testWidgets(
        'shows and hides info sidebar based on ViewStateService.isInfoOpen',
        (tester) async {
      await tester.pumpWidget(createTestApp(const PhotosApp()));
      await tester.pumpAndSettle();

      var panel =
          tester.widget<AnimatedInfoPanel>(find.byType(AnimatedInfoPanel));
      expect(panel.isOpen, isFalse);

      ViewStateService.instance.isInfoOpen.add(true);
      await tester.pumpAndSettle();

      panel =
          tester.widget<AnimatedInfoPanel>(find.byType(AnimatedInfoPanel));
      expect(panel.isOpen, isTrue);
    });

    testWidgets(
      'map view gets only geotagged photos from photosWithLocation, not the '
      'full unfiltered library',
      (tester) async {
        // Regression test: PhotoMapView used to receive the same `_files`
        // list as Grid/List (the whole library, including every photo
        // without GPS data), and filtered non-geotagged photos out itself in
        // Dart — meaning Map loaded the entire library into memory just to
        // discard most of it. It now gets the DB-filtered
        // PhotosService.photosWithLocation stream instead.
        final now = DateTime(2026, 1, 1);
        File makeFile(String id, {double? lat, double? lng}) => File(
              id: id,
              name: '$id.jpg',
              path: '$id.jpg',
              parent: '',
              dateCreated: now,
              dateLastModified: now,
              collectionId: 'col-1',
              contentType: 'image/jpeg',
              size: 1,
              isDeleted: false,
              latitude: lat,
              longitude: lng,
            );

        final withGps = makeFile('geo-1', lat: 35.0, lng: 139.0);
        final withoutGps = makeFile('no-geo-1');

        await tester.pumpWidget(createTestApp(const PhotosApp()));
        await tester.pumpAndSettle();

        // Seeded after the widget settles: PhotosApp's activeFilter listener
        // fires PhotosService.invoke() as soon as it subscribes (BehaviorSubject
        // replay), which would otherwise overwrite this with the real (empty,
        // no DB in tests) query result.
        PhotosService.instance.sink.add([withGps, withoutGps]);
        PhotosService.instance.photosWithLocation.add([withGps]);
        await tester.pump();

        ViewStateService.instance.setViewMode(PhotoViewMode.map);
        await tester.pumpAndSettle();

        final mapView = tester.widget<PhotoMapView>(find.byType(PhotoMapView));
        expect(mapView.files.map((f) => f.id), [withGps.id]);
      },
    );
  });
}
