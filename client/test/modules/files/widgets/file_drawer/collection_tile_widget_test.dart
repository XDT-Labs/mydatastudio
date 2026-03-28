import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatatools/modules/files/widgets/file_drawer/collection_tile_widget.dart';
import '../../../../helpers/file_fixture.dart';

void main() {
  group('CollectionTileWidget', () {
    final col = makeTestCollection(id: 'c1', name: 'My Photos');

    testWidgets('shows display name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionTileWidget(
              collection: col,
              isSelected: false,
              displayName: 'My Photos',
              onTap: () {},
              onSync: () {},
              onDelete: () {},
            ),
          ),
        ),
      );

      expect(find.text('My Photos'), findsOneWidget);
    });

    testWidgets('shows subtitle when provided', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionTileWidget(
              collection: col,
              isSelected: false,
              displayName: 'My Photos',
              subtitle: '42 files',
              onTap: () {},
              onSync: () {},
              onDelete: () {},
            ),
          ),
        ),
      );

      expect(find.text('42 files'), findsOneWidget);
    });

    testWidgets('calls onTap when tapped', (tester) async {
      bool called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionTileWidget(
              collection: col,
              isSelected: false,
              displayName: 'My Photos',
              onTap: () => called = true,
              onSync: () {},
              onDelete: () {},
            ),
          ),
        ),
      );

      await tester.tap(find.byType(ListTile));
      await tester.pump();

      expect(called, isTrue);
    });
  });
}
