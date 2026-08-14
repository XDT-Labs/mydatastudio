import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/photo_grid_tile.dart';

File _createTestFile({
  String id = 'file-1',
  String name = 'photo1.jpg',
  String contentType = 'image/jpeg',
  double? latitude,
  double? longitude,
}) {
  return File(
    id: id,
    name: name,
    path: '/test/$name',
    parent: '/test',
    dateCreated: DateTime(2026, 7, 15),
    dateLastModified: DateTime(2026, 7, 15),
    collectionId: 'col-1',
    contentType: contentType,
    size: 2048,
    isDeleted: false,
    latitude: latitude,
    longitude: longitude,
  );
}

Widget _buildTestableWidget(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 200,
          height: 200,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders thumbnail fallback or image', (WidgetTester tester) async {
    final file = _createTestFile();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGridTile(
          file: file,
          isSelected: false,
          onTap: () {},
          onSelect: () {},
          onToggleFavorite: () {},
          onOpenLightbox: () {},
          onOpenInfo: () {},
        ),
      ),
    );

    expect(find.byType(PhotoGridTile), findsOneWidget);
    expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
  });

  testWidgets('hover shows overlay controls', (WidgetTester tester) async {
    final file = _createTestFile();
    bool selectCalled = false;
    bool favoriteCalled = false;
    bool lightboxCalled = false;

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGridTile(
          file: file,
          isSelected: false,
          onTap: () {},
          onSelect: () => selectCalled = true,
          onToggleFavorite: () => favoriteCalled = true,
          onOpenLightbox: () => lightboxCalled = true,
          onOpenInfo: () {},
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(PhotoGridTile)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsOneWidget);

    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.favorite_border)));
    await tester.pumpAndSettle();
    await gesture.down(tester.getCenter(find.byIcon(Icons.favorite_border)));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(favoriteCalled, isTrue);

    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.radio_button_unchecked)));
    await tester.pumpAndSettle();
    await gesture.down(tester.getCenter(find.byIcon(Icons.radio_button_unchecked)));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(selectCalled, isTrue);

    await gesture.moveTo(tester.getCenter(find.byIcon(Icons.open_in_full)));
    await tester.pumpAndSettle();
    await gesture.down(tester.getCenter(find.byIcon(Icons.open_in_full)));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(lightboxCalled, isTrue);

    await gesture.removePointer();
  });

  testWidgets('selected state shows border and checked icon', (WidgetTester tester) async {
    final file = _createTestFile();

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGridTile(
          file: file,
          isSelected: true,
          onTap: () {},
          onSelect: () {},
          onToggleFavorite: () {},
          onOpenLightbox: () {},
          onOpenInfo: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    final animatedContainerFinder = find.byType(AnimatedContainer);
    expect(animatedContainerFinder, findsOneWidget);
    final container = tester.widget<AnimatedContainer>(animatedContainerFinder);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.border, isNotNull);
    expect(decoration.border!.top.color, equals(darkColorScheme.primary));
    expect(decoration.border!.top.width, equals(2.0));
  });

  testWidgets('tap calls onTap callback', (WidgetTester tester) async {
    final file = _createTestFile();
    bool tapCalled = false;

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGridTile(
          file: file,
          isSelected: false,
          onTap: () => tapCalled = true,
          onSelect: () {},
          onToggleFavorite: () {},
          onOpenLightbox: () {},
          onOpenInfo: () {},
        ),
      ),
    );

    await tester.tap(find.byType(PhotoGridTile));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tapCalled, isTrue);
  });

  testWidgets('video files show duration badge', (WidgetTester tester) async {
    final videoFile = _createTestFile(
      contentType: 'video/mp4',
    );

    await tester.pumpWidget(
      _buildTestableWidget(
        PhotoGridTile(
          file: videoFile,
          isSelected: false,
          onTap: () {},
          onSelect: () {},
          onToggleFavorite: () {},
          onOpenLightbox: () {},
          onOpenInfo: () {},
        ),
      ),
    );

    expect(find.byIcon(Icons.movie_outlined), findsOneWidget);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(PhotoGridTile)));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.text('0:32'), findsOneWidget);

    await gesture.removePointer();
  });
}
