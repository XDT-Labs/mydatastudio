import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer/email_folder_tile_widget.dart';
import '../../../../helpers/email_fixture.dart';

void main() {
  group('EmailDrawer widget tests', () {
    testWidgets('EmailFolderTileWidget uses expected default indent', (tester) async {
      final folder = makeTestEmailFolder(name: 'Inbox');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'Inbox',
              icon: Icons.inbox,
              isSelected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      final listTile = tester.widget<ListTile>(find.byType(ListTile));
      final EdgeInsets contentPadding = listTile.contentPadding as EdgeInsets;
      // Default indent is 48.0, so left content padding inside ListTile is 48.0 - 8.0 = 40.0
      expect(contentPadding.left, equals(40.0));
    });

    testWidgets('EmailFolderTileWidget custom indent and fontSize for subfolders', (tester) async {
      final folder = makeTestEmailFolder(name: 'YELLOW_STAR');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'YELLOW_STAR',
              indent: 72.0,
              fontSize: 10.0,
              isSelected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      final listTile = tester.widget<ListTile>(find.byType(ListTile));
      final EdgeInsets contentPadding = listTile.contentPadding as EdgeInsets;
      // Indent of 72.0 gives left content padding of 72.0 - 8.0 = 64.0 (aligns text with "All Folders" text)
      expect(contentPadding.left, equals(64.0));

      final text = tester.widget<Text>(find.text('YELLOW_STAR'));
      expect(text.style?.fontSize, equals(10.0));
    });
  });
}
