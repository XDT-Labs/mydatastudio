import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/widgets/views/photo_list_view.dart';

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
      size: 1024 * 1024 * 5, // 5.0 MB
      isDeleted: false,
      latitude: 37.7749,
      longitude: -122.4194,
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
      size: 2048, // 2.0 KB
      isDeleted: false,
    ),
  ];
}

Widget _buildTestableWidget(
  Widget child, {
  double width = 1000,
  double height = 800,
}) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(body: SizedBox(width: width, height: height, child: child)),
  );
}

void main() {
  testWidgets('renders header row and data rows', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(PhotoListView(files: files, selectedIds: const {})),
    );

    // Verify header column titles are rendered
    expect(find.text('Thumbnail + Title'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.text('Camera / Details'), findsOneWidget);
    expect(find.text('Actions'), findsOneWidget);

    // Verify row contents are rendered
    expect(find.text('july_photo1.jpg'), findsOneWidget);
    expect(find.text('july_photo2.jpg'), findsOneWidget);
    expect(find.text('Jul 20, 2026'), findsOneWidget);
    expect(find.text('Jul 10, 2026'), findsOneWidget);
    expect(find.text('37.77, -122.42'), findsOneWidget);
    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('5 MB'), findsOneWidget);
    expect(find.text('2 KB'), findsOneWidget);
  });

  testWidgets('row click triggers selection callback', (
    WidgetTester tester,
  ) async {
    final files = _createTestFiles();
    File? selectedFile;

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoListView(
          files: files,
          selectedIds: const {},
          onTapRow: (file) => selectedFile = file,
        ),
      ),
    );

    // Click first row by tapping file name
    await tester.tap(find.text('july_photo1.jpg'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(selectedFile, equals(files.first));
  });

  testWidgets('hover changes background color', (WidgetTester tester) async {
    final files = _createTestFiles();

    await tester.pumpWidget(
      _buildTestableWidget(PhotoListView(files: files, selectedIds: const {})),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();

    final initialContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('july_photo1.jpg'),
            matching: find.byType(Container),
          )
          .first,
    );
    final initialColor = (initialContainer.decoration as BoxDecoration).color;

    // Hover over the first row
    await mouse.moveTo(tester.getCenter(find.text('july_photo1.jpg')));
    await tester.pumpAndSettle();

    final hoveredContainer = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('july_photo1.jpg'),
            matching: find.byType(Container),
          )
          .first,
    );
    final hoveredColor = (hoveredContainer.decoration as BoxDecoration).color;

    expect(hoveredColor, isNot(equals(initialColor)));
  });

  testWidgets('empty state shows message when files list is empty', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _buildTestableWidget(const PhotoListView(files: [], selectedIds: {})),
    );

    expect(find.byIcon(Icons.photo_library), findsOneWidget);
    expect(find.text('No photos found'), findsOneWidget);
  });

  testWidgets('renders without overflow in narrow width layout', (
    WidgetTester tester,
  ) async {
    final files = _createTestFiles();

    // Render in a narrow width (400px) simulating open sidebar
    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoListView(files: files, selectedIds: const {}),
        width: 400,
        height: 600,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('july_photo1.jpg'), findsOneWidget);
  });
}
