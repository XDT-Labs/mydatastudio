import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/files/widgets/file_details/pill_list_section.dart';

void main() {
  group('PillListSection', () {
    testWidgets('renders nothing when items is empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PillListSection(
              title: 'Tags',
              icon: Icons.label_outline,
              items: const [],
              onDelete: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Tags'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('renders one pill per item with the title and icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PillListSection(
              title: 'Tags',
              icon: Icons.label_outline,
              items: const ['beach', 'sunset'],
              onDelete: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('TAGS'), findsOneWidget);
      expect(find.text('beach'), findsOneWidget);
      expect(find.text('sunset'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNWidgets(2));
    });

    testWidgets('tapping a pill\'s close icon calls onDelete with that item', (
      tester,
    ) async {
      String? deleted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PillListSection(
              title: 'Tags',
              icon: Icons.label_outline,
              items: const ['beach', 'sunset'],
              onDelete: (item) => deleted = item,
            ),
          ),
        ),
      );

      // Tap the close icon next to 'beach' specifically, not just the first
      // one found, so this fails if the wrong pill's callback fires.
      final beachPill = find.ancestor(
        of: find.text('beach'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(of: beachPill, matching: find.byIcon(Icons.close)),
      );
      await tester.pump();

      expect(deleted, 'beach');
    });

    testWidgets(
      'renders the "+" add pill (not empty) when onAdd is set and items is empty',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PillListSection(
                title: 'Tags',
                icon: Icons.label_outline,
                items: const [],
                onDelete: (_) {},
                onAdd: (_) {},
              ),
            ),
          ),
        );

        expect(find.text('TAGS'), findsOneWidget);
        expect(find.byIcon(Icons.add), findsOneWidget);
      },
    );

    testWidgets('tapping "+" reveals a text field; submitting calls onAdd and '
        'collapses back to the "+" pill', (tester) async {
      String? added;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PillListSection(
              title: 'Tags',
              icon: Icons.label_outline,
              items: const ['beach'],
              onDelete: (_) {},
              onAdd: (item) => added = item,
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'sunset');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(added, 'sunset');
      expect(find.byType(TextField), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('submitting an empty field does not call onAdd', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PillListSection(
              title: 'Tags',
              icon: Icons.label_outline,
              items: const [],
              onDelete: (_) {},
              onAdd: (_) => called = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(called, isFalse);
    });

    testWidgets(
      'submitting a value that matches an existing item case-insensitively '
      'does not call onAdd',
      (tester) async {
        var called = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PillListSection(
                title: 'Tags',
                icon: Icons.label_outline,
                items: const ['beach'],
                onDelete: (_) {},
                onAdd: (_) => called = true,
              ),
            ),
          ),
        );

        await tester.tap(find.byIcon(Icons.add));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'BEACH');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        expect(called, isFalse);
      },
    );
  });
}
