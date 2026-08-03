import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_map_view.dart';
import 'package:mydatastudio/modules/photos/widgets/views/trip_playback_controller.dart';

import '../../../../helpers/fake_tile_provider.dart';

List<File> _createTestFilesWithGps() {
  return [
    File(
      id: 'f1',
      name: 'tokyo_sunset.jpg',
      path: '/test/tokyo_sunset.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 7, 20),
      dateLastModified: DateTime(2026, 7, 20),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 1024,
      isDeleted: false,
      latitude: 35.6762,
      longitude: 139.6503,
    ),
    File(
      id: 'f2',
      name: 'kyoto_temple.jpg',
      path: '/test/kyoto_temple.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 7, 22),
      dateLastModified: DateTime(2026, 7, 22),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 2048,
      isDeleted: false,
      latitude: 35.0116,
      longitude: 135.7681,
    ),
    File(
      id: 'f3',
      name: 'no_gps_photo.jpg',
      path: '/test/no_gps_photo.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 7, 25),
      dateLastModified: DateTime(2026, 7, 25),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 4096,
      isDeleted: false,
      latitude: null,
      longitude: null,
    ),
  ];
}

Widget _buildTestableWidget(Widget child,
    {double width = 1000, double height = 800}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(
      body: SizedBox(
        width: width,
        height: height,
        child: child,
      ),
    ),
  );
}

void main() {
  testWidgets('renders map when files with coordinates provided',
      (WidgetTester tester) async {
    final files = _createTestFilesWithGps();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoMapView(
          files: files,
          selectedIds: const {},
          tileProvider: FakeMemoryTileProvider(),
        ),
      ),
    );
    await tester.pump();

    // Map should be rendered
    expect(find.byType(FlutterMap), findsOneWidget);
    // PolylineLayer and MarkerLayer present
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.byType(MarkerLayer), findsOneWidget);
    // Trip playback controller present
    expect(find.byType(TripPlaybackController), findsOneWidget);
  });

  testWidgets('markers placed for geotagged files',
      (WidgetTester tester) async {
    final files = _createTestFilesWithGps();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoMapView(
          files: files,
          selectedIds: const {},
          tileProvider: FakeMemoryTileProvider(),
        ),
      ),
    );
    await tester.pump();

    // Geotagged markers (f1 and f2) should exist
    expect(find.byKey(const Key('photo_marker_f1')), findsOneWidget);
    expect(find.byKey(const Key('photo_marker_f2')), findsOneWidget);
    // Non-geotagged file (f3) should not have a marker
    expect(find.byKey(const Key('photo_marker_f3')), findsNothing);
  });

  testWidgets('empty state when no geotagged files',
      (WidgetTester tester) async {
    final filesNoGps = [
      File(
        id: 'f3',
        name: 'no_gps_photo.jpg',
        path: '/test/no_gps_photo.jpg',
        parent: '/test',
        dateCreated: DateTime(2026, 7, 25),
        dateLastModified: DateTime(2026, 7, 25),
        collectionId: 'col-1',
        contentType: 'image/jpeg',
        size: 4096,
        isDeleted: false,
        latitude: null,
        longitude: null,
      ),
    ];

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoMapView(
          files: filesNoGps,
          selectedIds: const {},
          tileProvider: FakeMemoryTileProvider(),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('photo_map_empty_state')), findsOneWidget);
    expect(find.text('No geotagged photos found'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
  });

  testWidgets('trip playback controller renders controls',
      (WidgetTester tester) async {
    final files = _createTestFilesWithGps();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoMapView(
          files: files,
          selectedIds: const {},
          tileProvider: FakeMemoryTileProvider(),
        ),
      ),
    );
    await tester.pump();

    // Verify trip playback controls exist
    expect(find.byKey(const Key('trip_playback_play_pause_button')), findsOneWidget);
    expect(find.byKey(const Key('trip_playback_reset_button')), findsOneWidget);
    expect(find.byKey(const Key('trip_playback_speed_dropdown')), findsOneWidget);
    expect(find.byKey(const Key('trip_playback_slider')), findsOneWidget);
    expect(find.text('tokyo_sunset.jpg'), findsOneWidget);
  });
}
