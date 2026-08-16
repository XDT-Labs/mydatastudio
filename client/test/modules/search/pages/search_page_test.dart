import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/color_schemes.g.dart';
import 'package:mydatastudio/models/tables/collection.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/models/tables/file.dart' as model;
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/pages/search_page.dart';
import 'package:mydatastudio/modules/search/services/search_detail_repository.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_facet_bar.dart';
import 'package:mydatastudio/modules/search/widgets/search_filter_chips.dart';
import 'package:mydatastudio/modules/search/widgets/search_result_tile.dart';

Widget _buildTestableWidget(Widget child) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true, colorScheme: darkColorScheme),
    home: Scaffold(body: child),
  );
}

SearchResult _email({
  String id = 'e1',
  String title = 'Quarterly report',
  String? subtitle = 'alice@example.com',
  String? snippet = 'Attached is the report you asked for last week.',
  double score = 1.0,
}) {
  return SearchResult(
    id: id,
    type: SearchResultType.email,
    title: title,
    subtitle: subtitle,
    snippet: snippet,
    date: DateTime(2026, 3, 1),
    score: score,
  );
}

SearchResult _file({
  String id = 'f1',
  String title = 'vacation.jpg',
  String? subtitle = '/Photos/2026/vacation.jpg',
  String? snippet,
  String? thumbnail,
  String contentType = 'image/jpeg',
  double score = 1.0,
}) {
  return SearchResult(
    id: id,
    type: SearchResultType.file,
    title: title,
    subtitle: subtitle,
    snippet: snippet,
    date: DateTime(2026, 3, 2),
    score: score,
    contentType: contentType,
    thumbnail: thumbnail,
  );
}

/// Stands in for the database behind the detail sidebars.
///
/// Widget tests have no `AppDatabase`, so the real repository would return null
/// for everything and the panel would only ever render its "couldn't load"
/// state — which is exactly the state these tests need to distinguish from a
/// successful open.
///
/// [emailById] always returns null, and the tests below only ever select files.
/// The email panel is not reachable from a widget test at all: `EmailDetails`
/// builds a `WebViewController` in `initState`, and `webview_flutter` has no
/// platform implementation under `flutter test`, so constructing it throws.
/// Covering the mail path needs an integration test on a real device.
class _FakeDetailLoader implements SearchDetailRepository {
  _FakeDetailLoader({this.file, this.collection});

  final model.File? file;
  final Collection? collection;

  @override
  Future<model.File?> fileById(String id) async => file;

  @override
  Future<Email?> emailById(String id) async => null;

  @override
  Future<Collection?> collectionById(String id) async => collection;
}

model.File _fileRecord({String id = 'f1', String name = 'vacation.jpg'}) {
  return model.File(
    id: id,
    name: name,
    path: 'Photos/2026/$name',
    parent: 'Photos/2026',
    dateCreated: DateTime(2026, 3, 2),
    dateLastModified: DateTime(2026, 3, 2),
    collectionId: 'c1',
    contentType: 'image/jpeg',
    size: 1024,
    isDeleted: false,
  );
}

Collection _collectionRecord() {
  return Collection(
    id: 'c1',
    name: 'Local Files',
    path: '/tmp/does-not-exist',
    type: 'files',
    scanner: 'local',
    scanStatus: 'idle',
    needsReAuth: false,
  );
}

/// Taps the single result row and waits for the detail panel to load.
///
/// The extra wait is not padding: the row carries both a tap and a double-tap
/// handler, so the gesture arena holds the single tap until the double-tap
/// window closes. Pumping zero-duration frames never gets there.
Future<void> _tapRowAndSettle(WidgetTester tester) async {
  await tester.tap(find.byType(SearchResultTile));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// The row's own background/border container — the first [Container] under the
/// tile, ahead of the one the icon fallback builds.
BoxDecoration _rowDecoration(WidgetTester tester) {
  final container = tester.widget<Container>(
    find
        .descendant(
          of: find.byType(SearchResultTile),
          matching: find.byType(Container),
        )
        .first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  // These pure widgets never touch SearchService/DatabaseManager, so they
  // don't need the RxService reset() dance the SearchPage tests do below.
  group('SearchResultTile', () {
    testWidgets('renders title, subtitle and snippet but never the raw score', (
      tester,
    ) async {
      final result = _email(title: 'Quarterly report', score: 12.345);

      await tester.pumpWidget(
        _buildTestableWidget(SearchResultTile(result: result)),
      );

      expect(find.text('Quarterly report'), findsOneWidget);
      expect(find.text('alice@example.com'), findsOneWidget);
      expect(
        find.text('Attached is the report you asked for last week.'),
        findsOneWidget,
      );
      // The score must never leak into the UI in any of its usual forms.
      expect(find.textContaining('12.345'), findsNothing);
      expect(find.textContaining('12.3'), findsNothing);
    });

    testWidgets('email result shows a mail icon, not a thumbnail image', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(SearchResultTile(result: _email())),
      );

      expect(find.byIcon(Icons.mail_outline), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('file result without a thumbnail shows a content-type icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchResultTile(result: _file(contentType: 'application/pdf')),
        ),
      );

      expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
      expect(find.byIcon(Icons.mail_outline), findsNothing);
    });

    testWidgets('tapping the tile invokes onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchResultTile(result: _email(), onTap: () => tapped = true),
        ),
      );

      await tester.tap(find.byType(SearchResultTile));
      expect(tapped, isTrue);
    });

    testWidgets('renders the thumbnail big enough to judge an image by eye', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(SearchResultTile(result: _file())),
      );

      // This list is how the relevance of a semantic image search gets
      // judged. At the 40px the other modules' list views use, a white swan
      // and a white dog are the same smudge and every hit has to be opened to
      // tell them apart — so the size is a requirement, not a style choice.
      final leading =
          find
              .descendant(
                of: find.byType(SearchResultTile),
                matching: find.byType(SizedBox),
              )
              .first;
      expect(tester.getSize(leading), const Size(100, 100));
    });

    testWidgets('the selected row is marked so the list and panel agree', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(SearchResultTile(result: _file())),
      );
      final unselected = _rowDecoration(tester).border! as Border;
      expect(unselected.left.color, Colors.transparent);

      await tester.pumpWidget(
        _buildTestableWidget(
          SearchResultTile(result: _file(), isSelected: true),
        ),
      );
      // Without the accent bar, an open detail panel names a row the user has
      // no way to locate again in a long scrolled list.
      final selected = _rowDecoration(tester).border! as Border;
      expect(selected.left.color, darkColorScheme.primary);
    });
  });

  group('SearchFilterChips', () {
    testWidgets('renders nothing for an empty filter list', (tester) async {
      await tester.pumpWidget(
        _buildTestableWidget(const SearchFilterChips(filters: [])),
      );

      expect(find.byType(InputChip), findsNothing);
    });

    testWidgets('negated filter shows a leading "-"', (tester) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          const SearchFilterChips(
            filters: [
              QueryFilter(field: FilterField.tag, value: 'spam', negated: true),
            ],
          ),
        ),
      );

      expect(find.text('-tag:spam'), findsOneWidget);
    });

    testWidgets('is_ and in_ display without the trailing underscore', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          const SearchFilterChips(
            filters: [
              QueryFilter(field: FilterField.is_, value: 'unread'),
              QueryFilter(field: FilterField.in_, value: 'Work Gmail'),
            ],
          ),
        ),
      );

      expect(find.text('is:unread'), findsOneWidget);
      expect(find.text('in:Work Gmail'), findsOneWidget);
      expect(find.textContaining('is_'), findsNothing);
      expect(find.textContaining('in_'), findsNothing);
    });

    testWidgets('near filter with a radius shows the km hint', (tester) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          const SearchFilterChips(
            filters: [
              QueryFilter(
                field: FilterField.near,
                value: 'Seattle',
                radiusKm: 25,
              ),
            ],
          ),
        ),
      );

      expect(find.text('near:Seattle (25km)'), findsOneWidget);
    });

    testWidgets('after filter formats dateValue as yyyy-MM-dd', (tester) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchFilterChips(
            filters: [
              QueryFilter(
                field: FilterField.after,
                value: '2026',
                dateValue: DateTime(2026, 1, 1),
              ),
            ],
          ),
        ),
      );

      expect(find.text('after:2026-01-01'), findsOneWidget);
    });

    testWidgets('deleting a chip calls onRemove with that filter', (
      tester,
    ) async {
      QueryFilter? removed;
      const filter = QueryFilter(field: FilterField.subject, value: 'invoice');

      await tester.pumpWidget(
        _buildTestableWidget(
          SearchFilterChips(
            filters: const [filter],
            onRemove: (f) => removed = f,
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.close));
      expect(removed, filter);
    });
  });

  group('SearchFacetBar / filterResultsByFacet', () {
    testWidgets(
      'reports All/Emails/Photos & Files counts from the totals passed in',
      (tester) async {
        await tester.pumpWidget(
          _buildTestableWidget(
            SearchFacetBar(
              total: 7,
              emailTotal: 4,
              fileTotal: 3,
              selected: SearchFacet.all,
              onSelected: (_) {},
            ),
          ),
        );

        expect(find.text('All 7'), findsOneWidget);
        expect(find.text('Emails 4'), findsOneWidget);
        expect(find.text('Photos & Files 3'), findsOneWidget);
      },
    );

    testWidgets('tapping a facet reports the selection via onSelected', (
      tester,
    ) async {
      SearchFacet? selected;
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchFacetBar(
            total: 2,
            emailTotal: 1,
            fileTotal: 1,
            selected: SearchFacet.all,
            onSelected: (f) => selected = f,
          ),
        ),
      );

      await tester.tap(find.text('Emails 1'));
      expect(selected, SearchFacet.email);
    });

    test('a facet maps to the source retrieval is restricted to', () {
      // Facets re-query rather than slicing the loaded rows. The counts on the
      // bar are archive totals, so selecting "Photos & Files 1,134" has to be
      // able to reach all of them — slicing could only ever show the pages
      // already fetched alongside the mail.
      expect(sourceTypeForFacet(SearchFacet.all), isNull);
      expect(sourceTypeForFacet(SearchFacet.email), SearchResultType.email);
      expect(sourceTypeForFacet(SearchFacet.file), SearchResultType.file);
    });
  });

  group('SearchPage', () {
    // SearchService is a singleton BehaviorSubject-backed service; reset()
    // between tests so one test's search results can't bleed into the next.
    setUp(() {
      SearchService.instance.reset();
    });

    testWidgets(
      'empty initialQuery shows a neutral prompt, not a "no results" message',
      (tester) async {
        await tester.pumpWidget(
          _buildTestableWidget(const SearchPage(initialQuery: '')),
        );
        await tester.pump();

        expect(
          find.text('Search your files, emails, and photos'),
          findsOneWidget,
        );
        expect(find.textContaining('No results'), findsNothing);
      },
    );

    testWidgets(
      'non-empty initialQuery with no results shows the empty-results message',
      (tester) async {
        // No database is wired up in this widget test, so the search never
        // actually runs — the page is left with an empty result set for a
        // non-blank query, which is exactly the "empty results" state.
        await tester.pumpWidget(
          _buildTestableWidget(const SearchPage(initialQuery: 'zzz_no_match')),
        );
        await tester.pump();

        expect(find.text('No results for "zzz_no_match"'), findsOneWidget);
        expect(
          find.text('Search your files, emails, and photos'),
          findsNothing,
        );
      },
    );

    testWidgets('prefills the search field with initialQuery', (tester) async {
      await tester.pumpWidget(
        _buildTestableWidget(const SearchPage(initialQuery: 'invoices')),
      );
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller?.text, 'invoices');
    });

    testWidgets('selecting a result opens a detail panel for that result', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchPage(
            initialQuery: 'vacation',
            detailLoader: _FakeDetailLoader(
              file: _fileRecord(),
              collection: _collectionRecord(),
            ),
          ),
        ),
      );
      await tester.pump();
      SearchService.instance.sink.add(
        SearchResults(results: [_file()], fileTotal: 1),
      );
      await tester.pump();
      expect(find.text('File Details'), findsNothing);

      await _tapRowAndSettle(tester);

      expect(find.text('File Details'), findsOneWidget);
    });

    testWidgets('running a new query closes the panel from the old results', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchPage(
            initialQuery: 'vacation',
            detailLoader: _FakeDetailLoader(
              file: _fileRecord(),
              collection: _collectionRecord(),
            ),
          ),
        ),
      );
      await tester.pump();
      SearchService.instance.sink.add(
        SearchResults(results: [_file()], fileTotal: 1),
      );
      await tester.pump();
      await _tapRowAndSettle(tester);
      expect(find.text('File Details'), findsOneWidget);

      // The panel is keyed to a position in the result list. A new query
      // replaces that list wholesale, so a panel that survived would keep
      // describing a file the new results never contained.
      await tester.enterText(find.byType(TextField), 'something else');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('File Details'), findsNothing);
    });

    testWidgets('space with nothing selected does not open a viewer', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildTestableWidget(
          SearchPage(
            initialQuery: 'vacation',
            detailLoader: _FakeDetailLoader(
              file: _fileRecord(),
              collection: _collectionRecord(),
            ),
          ),
        ),
      );
      await tester.pump();
      SearchService.instance.sink.add(
        SearchResults(results: [_file()], fileTotal: 1),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      // A full-window viewer over an empty selection has nothing to show and
      // no obvious way back — the key has to be inert until a row is picked.
      expect(find.byTooltip('Close'), findsNothing);
    });
  });
}
