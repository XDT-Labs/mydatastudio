import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/photos/widgets/tiles/cluster_section_header.dart';

const double _width = 800;

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: _width, child: child),
      ),
    );

void main() {
  group('ClusterSectionHeader layout', () {
    // The bug this pins down: the label was Flexible and the trailing group was
    // pushed by a Spacer, and both default to flex 1 — so they split the free
    // space rather than the Spacer taking it. The count and chevron landed
    // mid-row and drifted with the length of the generated label.
    testWidgets('count and chevron stay pinned however long the label is',
        (tester) async {
      Future<double> trailingEdgeFor(String label) async {
        await tester.pumpWidget(_wrap(ClusterSectionHeader(
          label: label,
          itemCount: 149,
          onToggleCollapsed: () {},
        )));
        await tester.pumpAndSettle();
        return tester.getTopRight(find.byType(IconButton)).dx;
      }

      final short = await trailingEdgeFor('Swans');
      final long = await trailingEdgeFor(
        'A very long generated label that runs on well past the middle',
      );

      expect(short, long,
          reason: 'the trailing group must not move with the label');
      expect(short, greaterThan(_width - 40),
          reason: 'and it must actually reach the trailing edge');
    });

    testWidgets('the count sits beside the chevron, not beside the label',
        (tester) async {
      await tester.pumpWidget(_wrap(ClusterSectionHeader(
        label: 'Coastal village',
        itemCount: 149,
        onToggleCollapsed: () {},
      )));
      await tester.pumpAndSettle();

      final labelRight = tester.getTopRight(find.text('Coastal village')).dx;
      final countLeft = tester.getTopLeft(find.text('149 items')).dx;
      final chevronLeft = tester.getTopLeft(find.byType(IconButton)).dx;

      expect(countLeft, greaterThan(labelRight + 100),
          reason: 'the count belongs at the far end, not next to the label');
      expect(chevronLeft, greaterThan(countLeft));
    });

    // The markers describe the label, so they have to travel with it rather
    // than being flung to the opposite end of the row by the expanding cell.
    testWidgets('pending and mixed markers stay beside the label',
        (tester) async {
      await tester.pumpWidget(_wrap(const ClusterSectionHeader(
        label: 'Group 3',
        itemCount: 12,
        isLabelPending: true,
        isMixed: true,
      )));
      // Not pumpAndSettle: the pending spinner animates forever, so there is
      // no settled frame to wait for.
      await tester.pump();

      final labelRight = tester.getTopRight(find.text('Group 3')).dx;
      final spinnerLeft =
          tester.getTopLeft(find.byType(CircularProgressIndicator)).dx;
      final markerLeft = tester.getTopLeft(find.byIcon(Icons.blur_on)).dx;

      expect(spinnerLeft, closeTo(labelRight + 8, 2));
      expect(markerLeft, lessThan(_width / 2),
          reason: 'markers belong with the label, not at the far edge');
    });

    testWidgets('no disclosure control when the view cannot collapse',
        (tester) async {
      await tester.pumpWidget(_wrap(const ClusterSectionHeader(
        label: 'Swans',
        itemCount: 3,
      )));
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('3 items'), findsOneWidget);
    });

    testWidgets('the chevron points the way the content is', (tester) async {
      await tester.pumpWidget(_wrap(ClusterSectionHeader(
        label: 'Swans',
        itemCount: 3,
        onToggleCollapsed: () {},
      )));
      expect(find.byIcon(Icons.expand_more), findsOneWidget);

      await tester.pumpWidget(_wrap(ClusterSectionHeader(
        label: 'Swans',
        itemCount: 3,
        isCollapsed: true,
        onToggleCollapsed: () {},
      )));
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });
  });
}
