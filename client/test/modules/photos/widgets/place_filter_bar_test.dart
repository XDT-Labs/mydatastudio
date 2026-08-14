import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';
import 'package:mydatastudio/modules/photos/widgets/toolbar/place_filter_bar.dart';

/// Widening the radius is how you find out where a library's photos actually
/// cluster, so it belongs next to the results rather than inside a drawer.
void main() {
  const austin = PhotoPlaceFilter(
    label: 'Austin, Texas, United States',
    latitude: 30.26715,
    longitude: -97.74306,
  );

  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
      home: Scaffold(body: SizedBox(width: 1000, child: child)),
    );
  }

  testWidgets('names the place and its radius in miles', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin,
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.text('Austin, Texas, United States'), findsOneWidget);
    expect(find.text('25 miles'), findsOneWidget);
  });

  testWidgets('dragging the slider reports a new radius in miles', (
    tester,
  ) async {
    double? reported;

    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin,
          onRadiusChanged: (miles) => reported = miles,
          onCleared: () {},
        ),
      ),
    );

    await tester.drag(find.byType(Slider), const Offset(200, 0));
    await tester.pumpAndSettle();

    expect(reported, isNotNull);
    expect(
      reported,
      greaterThan(25),
      reason: 'dragging right has to widen the search, not narrow it',
    );
    expect(PhotoPlaceFilter.radiusMileOptions, contains(reported));
  });

  testWidgets('says why an empty result is empty', (tester) async {
    // An empty grid alone reads as a broken filter. Most photos carry no
    // coordinates at all, so no radius will ever reach them — worth saying
    // rather than leaving the user to widen forever.
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin,
          matchCount: 0,
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.textContaining('No geotagged photos here'), findsOneWidget);
  });

  testWidgets('reports how many photos the radius matched', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin,
          matchCount: 123,
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.text('123 photos'), findsOneWidget);
  });

  testWidgets('the filter can be cleared from the bar', (tester) async {
    var cleared = false;

    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin,
          onRadiusChanged: (_) {},
          onCleared: () => cleared = true,
        ),
      ),
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);
  });

  testWidgets('a landmark filter is shown too, without a radius', (
    tester,
  ) async {
    // Picking a landmark from the drawer narrows the grid just as a searched
    // place does, and showing nothing here left the user with a filtered grid
    // and no visible reason for it — or any way to clear it from the grid.
    // There is no distance to widen, so no slider.
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          landmark: 'Eiffel Tower',
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.text('Eiffel Tower'), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    expect(find.text('Within'), findsNothing);

    // And says why, rather than looking like a slider that failed to render.
    // These photos are found by what they show; in a real library almost none
    // of them carry coordinates, so there is no point to measure a distance
    // from and widening would return nothing at all.
    expect(find.text('recognised in photo'), findsOneWidget);
  });

  testWidgets('an empty landmark does not blame the radius', (tester) async {
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          landmark: 'Eiffel Tower',
          matchCount: 0,
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.textContaining('wider radius'), findsNothing);
    expect(find.text('No photos'), findsOneWidget);
  });

  testWidgets('a landmark filter can be cleared from the bar', (tester) async {
    var cleared = false;

    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          landmark: 'Eiffel Tower',
          onRadiusChanged: (_) {},
          onCleared: () => cleared = true,
        ),
      ),
    );

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);
  });

  testWidgets('a radius off the scale still rests on a stop', (tester) async {
    // Nothing guarantees the stored radius came from this slider.
    await tester.pumpWidget(
      wrap(
        PlaceFilterBar(
          place: austin.copyWith(radiusKm: 37),
          onRadiusChanged: (_) {},
          onCleared: () {},
        ),
      ),
    );

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('25 miles'), findsOneWidget);
  });
}
