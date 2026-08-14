import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/gazetteer_place.dart';
import 'package:mydatastudio/modules/photos/models/photo_place_filter.dart';
import 'package:mydatastudio/modules/photos/widgets/drawer/location_search_field.dart';
import 'package:mydatastudio/repositories/gazetteer_repository.dart';

class FakeGazetteerRepository extends GazetteerRepository {
  FakeGazetteerRepository(this.results);

  final List<GazetteerPlace> results;
  final List<String> queries = [];

  @override
  Future<List<GazetteerPlace>> search(String query, {int limit = 20}) async {
    queries.add(query);
    return results;
  }
}

const _austin = GazetteerPlace(
  name: 'Austin',
  region: 'Texas',
  country: 'United States',
  latitude: 30.26715,
  longitude: -97.74306,
  population: 974447,
);

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(body: SizedBox(width: 240, child: child)),
  );
}

void main() {
  group('LocationSearchField', () {
    testWidgets('does not query the gazetteer until typing settles', (
      tester,
    ) async {
      // Un-debounced, every keystroke is a LIKE over ~70k rows.
      final repo = FakeGazetteerRepository([_austin]);

      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: null,
            repository: repo,
            onSelected: (_) {},
            onCleared: () {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'a');
      await tester.enterText(find.byType(TextField), 'au');
      await tester.enterText(find.byType(TextField), 'aus');
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.queries, isEmpty);

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      expect(repo.queries, ['aus']);
    });

    testWidgets('picking a suggestion reports the place and its coordinates', (
      tester,
    ) async {
      PhotoPlaceFilter? selected;

      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: null,
            repository: FakeGazetteerRepository([_austin]),
            onSelected: (place) => selected = place,
            onCleared: () {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'austin');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Austin, Texas, United States'));
      await tester.pumpAndSettle();

      // Coordinates, not the name: the filter searches EXIF lat/lng, so a
      // place that arrived without them would filter nothing.
      expect(selected!.latitude, 30.26715);
      expect(selected!.longitude, -97.74306);
      expect(selected!.label, 'Austin, Texas, United States');
      expect(selected!.radiusKm, PhotoPlaceFilter.defaultRadiusKm);
    });

    testWidgets('clears the suggestion list once one is picked', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: null,
            repository: FakeGazetteerRepository([_austin]),
            onSelected: (_) {},
            onCleared: () {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'austin');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Austin, Texas, United States'));
      await tester.pumpAndSettle();

      expect(find.text('Austin, Texas, United States'), findsNothing);
    });

    testWidgets('shows the active place and points at the radius control', (
      tester,
    ) async {

      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: const PhotoPlaceFilter(
              label: 'Austin, Texas, United States',
              latitude: 30.26715,
              longitude: -97.74306,
            ),
            repository: FakeGazetteerRepository(const []),
            onSelected: (_) {},
            onCleared: () {},
          ),
        ),
      );

      // The radius itself moved to the bar above the grid, where the results
      // it changes are visible; the drawer says so rather than leaving the
      // reader to hunt for it.
      expect(find.text('Austin, Texas, United States'), findsOneWidget);
      expect(find.textContaining('25 mi'), findsOneWidget);
      expect(find.textContaining('adjust above the grid'), findsOneWidget);
    });

    testWidgets('the active place can be cleared', (tester) async {
      var cleared = false;

      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: const PhotoPlaceFilter(
              label: 'Austin, Texas, United States',
              latitude: 30.26715,
              longitude: -97.74306,
            ),
            repository: FakeGazetteerRepository(const []),
            onSelected: (_) {},
            onCleared: () => cleared = true,
          ),
        ),
      );

      await tester.tap(find.byTooltip('Clear location filter'));
      await tester.pumpAndSettle();

      expect(cleared, isTrue);
    });

    testWidgets('emptying the box drops the suggestions', (tester) async {
      await tester.pumpWidget(
        _wrap(
          LocationSearchField(
            selected: null,
            repository: FakeGazetteerRepository([_austin]),
            onSelected: (_) {},
            onCleared: () {},
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'austin');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Austin, Texas, United States'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();

      expect(find.text('Austin, Texas, United States'), findsNothing);
    });
  });
}
