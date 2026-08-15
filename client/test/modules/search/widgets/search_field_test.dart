import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion.dart';
import 'package:mydatastudio/modules/search/services/suggestions/field_suggestion_service.dart';
import 'package:mydatastudio/modules/search/widgets/search_field.dart';

/// Contacts, without a database behind them.
class _FakeContacts extends CachedFieldSuggestionProvider {
  _FakeContacts(this._entries);

  final List<FieldSuggestion> _entries;

  @override
  Set<FilterField> get fields => const {FilterField.from, FilterField.to};

  @override
  Future<List<FieldSuggestion>> load() async => _entries;
}

const _mike = FieldSuggestion(
  value: 'mike@xdtlabs.com',
  label: 'Mike Nimer',
  detail: 'mike@xdtlabs.com',
  count: 412,
);
const _milly = FieldSuggestion(
  value: 'milly@example.com',
  label: 'Milly Barnes',
  count: 7,
);

void main() {
  late TextEditingController controller;
  late FocusNode focusNode;
  late List<String> submitted;

  setUp(() {
    controller = TextEditingController();
    focusNode = FocusNode();
    submitted = [];
  });

  tearDown(() {
    controller.dispose();
  });

  Future<void> pumpField(
    WidgetTester tester, {
    FieldSuggestionService? suggestions,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchField(
            controller: controller,
            focusNode: focusNode,
            onSubmitted: submitted.add,
            suggestions:
                suggestions ??
                FieldSuggestionService([
                  _FakeContacts([_mike, _milly]),
                ]),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Types [text] into the field and lets the debounce elapse.
  ///
  /// Goes through [WidgetTester.enterText] rather than assigning to the
  /// controller so the platform text-input connection is live — [pressEnter]
  /// depends on it, because that is the path a real Enter key travels.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
  }

  /// Presses Enter the way the platform does: as a text-input action, not as a
  /// raw key event. A `TextField`'s `onSubmitted` never fires from a synthetic
  /// keystroke, so testing this with `sendKeyEvent` would pass against a
  /// widget that does nothing at all.
  Future<void> pressEnter(WidgetTester tester) async {
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
  }

  group('opening the list', () {
    testWidgets('a field: with no value yet shows top correspondents', (
      tester,
    ) async {
      // Discoverability, per §13d — the list is useful before the user has
      // typed a single character of the value.
      await pumpField(tester);
      await type(tester, 'from:');
      expect(find.text('Mike Nimer'), findsOneWidget);
      expect(find.text('Milly Barnes'), findsOneWidget);
    });

    testWidgets('typing narrows the list', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:mil');
      expect(find.text('Milly Barnes'), findsOneWidget);
      expect(find.text('Mike Nimer'), findsNothing);
    });

    testWidgets('free text opens nothing', (tester) async {
      await pumpField(tester);
      await type(tester, 'vacation photos');
      expect(find.text('Mike Nimer'), findsNothing);
    });

    testWidgets('a field with no suggestions opens nothing', (tester) async {
      await pumpField(tester);
      await type(tester, 'subject:budget');
      expect(find.text('Mike Nimer'), findsNothing);
    });

    testWidgets('a value matching nothing closes the list', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:mi');
      expect(find.text('Mike Nimer'), findsOneWidget);
      await type(tester, 'from:zzzz');
      expect(find.text('Mike Nimer'), findsNothing);
    });

    testWidgets('no service means no completion and no crash', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchField(
              controller: controller,
              focusNode: focusNode,
              onSubmitted: submitted.add,
            ),
          ),
        ),
      );
      await type(tester, 'from:mi');
      expect(find.text('Mike Nimer'), findsNothing);
    });
  });

  group('keyboard', () {
    testWidgets('Enter accepts the highlighted suggestion and does not search', (
      tester,
    ) async {
      // The classic autocomplete bug: getting this backwards fires a search on
      // every completion, using the half-typed value being replaced.
      await pumpField(tester);
      await type(tester, 'from:mi');

      await pressEnter(tester);

      expect(controller.text, 'from:mike@xdtlabs.com ');
      expect(submitted, isEmpty);
    });

    testWidgets('Enter searches once the list is closed', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:mi');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await pressEnter(tester);

      expect(submitted, ['from:mi']);
    });

    testWidgets('arrow keys move the highlight, not the caret', (tester) async {
      // Without shortcuts bound nearer the field than Flutter's own text
      // editing shortcuts, ArrowDown would jump the caret to the end instead.
      await pumpField(tester);
      await type(tester, 'from:');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await pressEnter(tester);

      // Second row, ranked by volume: Mike (412) then Milly (7).
      expect(controller.text, 'from:milly@example.com ');
    });

    testWidgets('the highlight stops at the ends of the list', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:');

      // Up from the first row stays put rather than wrapping to the last.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await pressEnter(tester);

      expect(controller.text, 'from:mike@xdtlabs.com ');
    });

    testWidgets('Tab completes the highlighted entry', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:mi');

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(controller.text, 'from:mike@xdtlabs.com ');
    });

    testWidgets('Escape dismisses the list without changing the query', (
      tester,
    ) async {
      await pumpField(tester);
      await type(tester, 'from:mi');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Mike Nimer'), findsNothing);
      expect(controller.text, 'from:mi');
    });
  });

  group('accepting', () {
    testWidgets('clicking a row completes it', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:');

      await tester.tap(find.text('Milly Barnes'));
      await tester.pumpAndSettle();

      expect(controller.text, 'from:milly@example.com ');
    });

    testWidgets('accepting closes the list instead of reopening it', (
      tester,
    ) async {
      // Setting the text fires the controller listener, and a list that pops
      // straight back open makes the completion look like it did not take.
      await pumpField(tester);
      await type(tester, 'from:mi');

      await pressEnter(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('Mike Nimer'), findsNothing);
    });

    testWidgets('the caret lands after the completed value, ready to keep '
        'typing', (tester) async {
      await pumpField(tester);
      await type(tester, 'from:mi');

      await pressEnter(tester);

      expect(controller.selection.baseOffset, controller.text.length);
    });
  });
}
