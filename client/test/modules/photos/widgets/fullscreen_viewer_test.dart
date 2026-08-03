import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/widgets/viewer/fullscreen_viewer.dart';

import '../../../helpers/file_fixture.dart';

void main() {
  group('FullscreenViewer Widget Tests', () {
    late File imageFile1;
    late File imageFile2;
    late File videoFile;
    late List<File> mediaList;

    setUp(() {
      imageFile1 = makeTestFile(
        id: 'img1',
        name: 'Sunset.jpg',
        contentType: 'image/jpeg',
        size: 2048000,
        latitude: 37.7749,
        longitude: -122.4194,
      );

      imageFile2 = makeTestFile(
        id: 'img2',
        name: 'Mountain.jpg',
        contentType: 'image/jpeg',
        size: 4096000,
      );

      videoFile = makeTestFile(
        id: 'vid1',
        name: 'Vacation.mp4',
        contentType: 'video/mp4',
        size: 15000000,
      );

      mediaList = [imageFile1, imageFile2, videoFile];
    });

    Widget buildTestWidget({
      required File currentFile,
      required List<File> mediaList,
      required VoidCallback onClose,
      ValueChanged<File>? onToggleFavorite,
      ValueChanged<File>? onOpenInfo,
    }) {
      return MaterialApp(
        home: FullscreenViewer(
          currentFile: currentFile,
          mediaList: mediaList,
          onClose: onClose,
          onToggleFavorite: onToggleFavorite,
          onOpenInfo: onOpenInfo,
        ),
      );
    }

    testWidgets('renders correctly with an image file', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
      expect(find.byTooltip('Zoom In'), findsOneWidget);
      expect(find.byTooltip('Zoom Out'), findsOneWidget);
      expect(find.byTooltip('Start Slideshow'), findsOneWidget);
      expect(find.byTooltip('Info Details'), findsOneWidget);
      expect(find.byTooltip('Favorite'), findsOneWidget);
    });

    testWidgets('close button calls onClose', (WidgetTester tester) async {
      bool closed = false;

      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () => closed = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
    });

    testWidgets('navigation arrows cycle through mediaList', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);

      // Next
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      // Next to video
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('Video File (14.3 MB)'), findsOneWidget);

      // Cycle back to first item
      await tester.tap(find.byTooltip('Next'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);

      // Previous cycles to last item
      await tester.tap(find.byTooltip('Previous'));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);
    });

    testWidgets('zoom controls change zoom level', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('100%'), findsOneWidget);

      // Zoom In
      await tester.tap(find.byTooltip('Zoom In'));
      await tester.pumpAndSettle();
      expect(find.text('125%'), findsOneWidget);

      // Zoom Out
      await tester.tap(find.byTooltip('Zoom Out'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.byTooltip('Zoom Out'));
      await tester.pumpAndSettle();
      expect(find.text('75%'), findsOneWidget);

      // Reset
      await tester.tap(find.text('75%'));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
    });

    testWidgets('slideshow auto-advances', (WidgetTester tester) async {
      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);

      // Start slideshow
      await tester.tap(find.byTooltip('Start Slideshow'));
      await tester.pumpAndSettle();

      // Advance timer by 3500ms
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      // Advance timer again
      await tester.pump(const Duration(milliseconds: 3500));
      await tester.pumpAndSettle();
      expect(find.text('3 / 3'), findsOneWidget);

      // Pause slideshow
      await tester.tap(find.byTooltip('Pause Slideshow'));
      await tester.pumpAndSettle();
    });

    testWidgets('keyboard shortcuts work (Escape closes, arrows navigate)', (WidgetTester tester) async {
      bool closed = false;

      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () => closed = true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 / 3'), findsOneWidget);

      // ArrowRight -> Next
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.text('2 / 3'), findsOneWidget);

      // ArrowLeft -> Previous
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);

      // Escape -> Close
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('info button triggers onOpenInfo callback', (WidgetTester tester) async {
      File? openedFile;
      await tester.pumpWidget(
        buildTestWidget(
          currentFile: imageFile1,
          mediaList: mediaList,
          onClose: () {},
          onOpenInfo: (f) => openedFile = f,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Info Details'));
      await tester.pumpAndSettle();

      expect(openedFile, equals(imageFile1));
    });
  });
}
