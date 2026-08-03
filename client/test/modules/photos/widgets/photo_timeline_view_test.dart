import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/date_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_timeline_view.dart';
import 'package:mydatastudio/modules/photos/widgets/views/timeline_quick_jump.dart';

List<File> _createTestFiles() {
  return [
    File(
      id: 'f1',
      name: 'july_photo1.jpg',
      path: '/test/july_photo1.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 7, 20),
      dateLastModified: DateTime(2026, 7, 20),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 1024,
      isDeleted: false,
    ),
    File(
      id: 'f2',
      name: 'july_photo2.jpg',
      path: '/test/july_photo2.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 7, 10),
      dateLastModified: DateTime(2026, 7, 10),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 2048,
      isDeleted: false,
    ),
    File(
      id: 'f3',
      name: 'june_photo.jpg',
      path: '/test/june_photo.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 6, 15),
      dateLastModified: DateTime(2026, 6, 15),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 4096,
      isDeleted: false,
    ),
    File(
      id: 'f4',
      name: 'may_photo.jpg',
      path: '/test/may_photo.jpg',
      parent: '/test',
      dateCreated: DateTime(2026, 5, 5),
      dateLastModified: DateTime(2026, 5, 5),
      collectionId: 'col-1',
      contentType: 'image/jpeg',
      size: 8192,
      isDeleted: false,
    ),
  ];
}

Widget _buildTestableWidget(Widget child,
    {double width = 1000, double height = 2000}) {
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
  testWidgets('renders month-grouped sections', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoTimelineView(
          files: files,
          selectedIds: const {},
        ),
      ),
    );

    // Should render headers for July 2026, June 2026, May 2026
    expect(find.text('July 2026'), findsOneWidget);
    expect(find.text('June 2026'), findsOneWidget);
    expect(find.text('May 2026'), findsOneWidget);
    expect(find.byType(DateSectionHeader), findsNWidgets(3));

    // Should render PhotoGridTile for each file
    expect(find.byType(PhotoGridTile), findsNWidgets(4));
  });

  testWidgets('quick jump bar renders month labels', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoTimelineView(
          files: files,
          selectedIds: const {},
        ),
      ),
    );

    expect(find.byType(TimelineQuickJump), findsOneWidget);
    // Short month labels Jul, Jun, May
    expect(find.text('Jul'), findsOneWidget);
    expect(find.text('Jun'), findsOneWidget);
    expect(find.text('May'), findsOneWidget);
  });

  testWidgets('tapping quick jump scrolls to section', (WidgetTester tester) async {
    final files = _createTestFiles();
    final controller = ScrollController();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoTimelineView(
          files: files,
          selectedIds: const {},
          scrollController: controller,
        ),
      ),
    );

    expect(controller.offset, equals(0.0));

    // Tap 'May' in quick jump bar
    await tester.tap(find.text('May'));
    await tester.pumpAndSettle();

    // Scroll offset should have increased to scroll to May section
    expect(controller.offset, greaterThan(0.0));
  });

  testWidgets('empty state shows message when files list is empty',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      _buildTestableWidget(
        const PhotoTimelineView(
          files: [],
          selectedIds: {},
        ),
      ),
    );

    expect(find.byIcon(Icons.photo_library), findsOneWidget);
    expect(find.text('No photos found'), findsOneWidget);
    expect(find.byType(PhotoGridTile), findsNothing);
    expect(find.byType(TimelineQuickJump), findsOneWidget);
  });
}
