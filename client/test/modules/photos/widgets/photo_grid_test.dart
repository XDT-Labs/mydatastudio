import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/date_section_header.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_grid.dart';
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
  ];
}

Widget _buildTestableWidget(Widget child, {double width = 1000, double height = 800}) {
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
  testWidgets('renders grid with date-grouped sections', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGrid(
          files: files,
          selectedIds: const {},
        ),
      ),
    );

    // Should render two date section headers: July 2026 and June 2026
    expect(find.byType(DateSectionHeader), findsNWidgets(2));
    expect(find.text('July 2026'), findsOneWidget);
    expect(find.text('June 2026'), findsOneWidget);

    // Should render 3 PhotoGridTiles in total
    expect(find.byType(PhotoGridTile), findsNWidgets(3));
  });

  testWidgets('responsive column count at different widths', (WidgetTester tester) async {
    // Default itemSize=160: columns = (width / 160).round() clamped 1-12
    expect(PhotoGrid.getColumnCount(500), equals(3));   // 500/160=3.1 → 3
    expect(PhotoGrid.getColumnCount(750), equals(5));   // 750/160=4.7 → 5
    expect(PhotoGrid.getColumnCount(1000), equals(6));  // 1000/160=6.25 → 6
    expect(PhotoGrid.getColumnCount(1300), equals(8));  // 1300/160=8.1 → 8
    expect(PhotoGrid.getColumnCount(1600), equals(10)); // 1600/160=10 → 10

    // With a custom itemSize of 200
    expect(PhotoGrid.getColumnCount(800, itemSize: 200), equals(4));  // 800/200=4 → 4
    expect(PhotoGrid.getColumnCount(1200, itemSize: 200), equals(6)); // 1200/200=6 → 6
  });

  testWidgets('empty state shows message when files list is empty', (WidgetTester tester) async {
    await tester.pumpWidget(
      _buildTestableWidget(
        const PhotoGrid(
          files: [],
          selectedIds: {},
        ),
      ),
    );

    expect(find.byIcon(Icons.photo_library), findsOneWidget);
    expect(find.text('No photos found'), findsOneWidget);
    expect(find.byType(PhotoGridTile), findsNothing);
  });

  testWidgets('tile tap interactions trigger callbacks', (WidgetTester tester) async {
    final files = _createTestFiles();
    File? tappedFile;
    File? selectedFile;
    File? lightboxFile;

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGrid(
          files: files,
          selectedIds: const {},
          onTapTile: (file) => tappedFile = file,
          onSelectTile: (file) => selectedFile = file,
          onOpenLightboxTile: (file) => lightboxFile = file,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Single tap first tile
    await tester.tap(find.byType(PhotoGridTile).first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tappedFile, equals(files.first));

    // Trigger onSelect on tile widget
    final tileWidget = tester.widget<PhotoGridTile>(find.byType(PhotoGridTile).first);
    tileWidget.onSelect?.call();
    expect(selectedFile, equals(files.first));
  });

  testWidgets('selected tiles show selection styling', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGrid(
          files: files,
          selectedIds: {'f1'},
        ),
      ),
    );

    final tiles = tester.widgetList<PhotoGridTile>(find.byType(PhotoGridTile)).toList();
    expect(tiles[0].isSelected, isTrue);
    expect(tiles[1].isSelected, isFalse);
    expect(tiles[2].isSelected, isFalse);
  });

  testWidgets('renders timeline quick jump bar and jump interaction', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGrid(
          files: files,
          selectedIds: const {},
        ),
      ),
    );

    expect(find.byType(TimelineQuickJump), findsOneWidget);
    expect(find.text('Jul'), findsOneWidget);
    expect(find.text('Jun'), findsOneWidget);

    await tester.tap(find.text('Jun'));
    await tester.pumpAndSettle();
  });
}
