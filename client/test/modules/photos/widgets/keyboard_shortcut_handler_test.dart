import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/photos/services/photos_service.dart';
import 'package:mydatastudio/modules/photos/services/selection_service.dart';
import 'package:mydatastudio/modules/photos/services/view_state_service.dart';
import 'package:mydatastudio/modules/photos/widgets/dialogs/keyboard_shortcuts_modal.dart';
import 'package:mydatastudio/modules/photos/widgets/keyboard_shortcut_handler.dart';

File _createTestFile(String id, String name) {
  return File(
    id: id,
    name: name,
    path: '/photos/$name',
    parent: '/photos',
    dateCreated: DateTime(2026, 7, 15),
    dateLastModified: DateTime(2026, 7, 15),
    collectionId: 'col1',
    contentType: 'image/jpeg',
    size: 1024,
    isDeleted: false,
  );
}

Widget createTestApp(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: darkColorScheme,
    ),
    home: Scaffold(
      body: child,
    ),
  );
}

void main() {
  late File file1;
  late File file2;

  setUp(() {
    file1 = _createTestFile('f1', 'photo1.jpg');
    file2 = _createTestFile('f2', 'photo2.jpg');
    PhotosService.instance.sink.add([file1, file2]);
    SelectionService.instance.deselectAll();
    ViewStateService.instance.setLightboxMedia(null);
    ViewStateService.instance.closeInfo();
  });

  group('KeyboardShortcutHandler Widget Tests', () {
    testWidgets('I key toggles info sidebar', (tester) async {
      await tester.pumpWidget(createTestApp(
        KeyboardShortcutHandler(
          child: Container(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.isInfoOpen.value, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.isInfoOpen.value, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.pumpAndSettle();

      expect(ViewStateService.instance.isInfoOpen.value, isFalse);
    });

    testWidgets('Escape key closes lightbox, sidebar, or selection in priority order', (tester) async {
      await tester.pumpWidget(createTestApp(
        KeyboardShortcutHandler(
          child: Container(),
        ),
      ));
      await tester.pumpAndSettle();

      // Open lightbox, info sidebar, and select items
      ViewStateService.instance.openLightbox(file1);
      ViewStateService.instance.toggleInfo();
      SelectionService.instance.selectAll(['f1', 'f2']);
      await tester.pumpAndSettle();

      // 1st Escape -> Closes Lightbox
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(ViewStateService.instance.lightboxMedia.value, isNull);
      expect(ViewStateService.instance.isInfoOpen.value, isTrue);
      expect(SelectionService.instance.selectedIds.value, isNotEmpty);

      // 2nd Escape -> Closes Info Sidebar
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(ViewStateService.instance.isInfoOpen.value, isFalse);
      expect(SelectionService.instance.selectedIds.value, isNotEmpty);

      // 3rd Escape -> Deselects All
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(SelectionService.instance.selectedIds.value, isEmpty);
    });

    testWidgets('Ctrl+A selects all visible items', (tester) async {
      await tester.pumpWidget(createTestApp(
        KeyboardShortcutHandler(
          child: Container(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(SelectionService.instance.selectedIds.value, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(SelectionService.instance.selectedIds.value, containsAll(['f1', 'f2']));
    });

    testWidgets('Cmd+A selects all visible items on macOS', (tester) async {
      SelectionService.instance.deselectAll();
      await tester.pumpWidget(createTestApp(
        KeyboardShortcutHandler(
          child: Container(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(SelectionService.instance.selectedIds.value, isEmpty);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
      await tester.pumpAndSettle();

      expect(SelectionService.instance.selectedIds.value, containsAll(['f1', 'f2']));
    });

    testWidgets('? key opens KeyboardShortcutsModal dialog', (tester) async {
      await tester.pumpWidget(createTestApp(
        KeyboardShortcutHandler(
          child: Container(),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pumpAndSettle();

      expect(find.byType(KeyboardShortcutsModal), findsOneWidget);
      expect(find.text('Keyboard Shortcuts'), findsOneWidget);
    });
  });
}
