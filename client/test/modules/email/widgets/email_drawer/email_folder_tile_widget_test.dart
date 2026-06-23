import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/email/widgets/email_drawer/email_folder_tile_widget.dart';
import '../../../../helpers/email_fixture.dart';

void main() {
  group('EmailFolderTileWidget', () {
    testWidgets('shows folder label', (tester) async {
      final folder = makeTestEmailFolder(name: 'Inbox');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'Inbox',
              isSelected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('Inbox'), findsOneWidget);
    });

    testWidgets('shows unread badge when unread > 0', (tester) async {
      final folder = makeTestEmailFolder(messagesUnread: 5);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'Inbox',
              isSelected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('5'), findsOneWidget);
    });

    testWidgets('hides badge when unread is 0', (tester) async {
      final folder = makeTestEmailFolder(messagesUnread: 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'Inbox',
              isSelected: false,
              onTap: () {},
            ),
          ),
        ),
      );

      expect(find.text('0'), findsNothing);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      bool called = false;
      final folder = makeTestEmailFolder();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmailFolderTileWidget(
              folder: folder,
              label: 'Inbox',
              isSelected: false,
              onTap: () => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(called, isTrue);
    });

    testWidgets('shows optional icon', (tester) async {
      final folder = makeTestEmailFolder();

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

      expect(find.byIcon(Icons.inbox), findsOneWidget);
    });
  });
}
