import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';
import 'package:mydatastudio/widgets/adaptive_app_bar.dart';

class _FakeContacts extends CachedFieldSuggestionProvider {
  _FakeContacts(this._entries);

  final List<FieldSuggestion> _entries;

  @override
  Set<FilterField> get fields => const {FilterField.from};

  @override
  Future<List<FieldSuggestion>> load() async => _entries;
}

const _mike = FieldSuggestion(
  value: 'mike@xdtlabs.com',
  label: 'Mike Nimer',
  detail: 'mike@xdtlabs.com',
  count: 412,
);

void main() {
  Future<void> pumpBar(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AdaptiveAppBar(
            suggestions: FieldSuggestionService([
              _FakeContacts(const [_mike]),
            ]),
          ),
          body: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  testWidgets('the header field completes, not just the search page', (
    tester,
  ) async {
    // The header field is where a query is actually composed — you type it
    // from whatever module you are in. Completing only on the results page
    // means discovering a filter matched nothing *after* navigating.
    await pumpBar(tester);
    await type(tester, 'from:mi');

    expect(find.text('Mike Nimer'), findsOneWidget);
  });

  testWidgets('the dropdown hangs below the field, out of the app bar', (
    tester,
  ) async {
    // The field is a 36px box inside a 64px bar, so the list only fits by
    // rendering in the overlay above the page — it deliberately overhangs the
    // bar's lower edge. Anchoring it inside the bar's own subtree instead
    // would clip it to a sliver, or hide it entirely.
    await pumpBar(tester);
    await type(tester, 'from:mi');

    final field = tester.getRect(find.byType(TextField));
    final row = tester.getRect(find.text('Mike Nimer'));
    expect(row.top, greaterThan(field.bottom));
  });

  testWidgets('Enter in the header completes instead of navigating', (
    tester,
  ) async {
    // Submitting here pushes the search route. Doing that on the keystroke
    // that accepts a suggestion would navigate with the half-typed value.
    await pumpBar(tester);
    await type(tester, 'from:mi');

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'from:mike@xdtlabs.com ',
    );
    expect(find.byType(AdaptiveAppBar), findsOneWidget);
  });
}
