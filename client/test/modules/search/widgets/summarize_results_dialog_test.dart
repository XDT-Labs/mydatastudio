import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mydatastudio/modules/aichat/pages/aichat_page.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/result_set_summarizer.dart';
import 'package:mydatastudio/modules/search/widgets/summarize_results_dialog.dart';

ResultSetSummary _summary({
  required SummaryCoverage coverage,
  int itemsSummarized = 412,
  int matchTotal = 412,
}) => ResultSetSummary(
  text: 'They discussed the contract in June.',
  coverage: coverage,
  itemsSummarized: itemsSummarized,
  matchTotal: matchTotal,
  batches: 17,
);

Future<void> _pump(
  WidgetTester tester, {
  required SummarizeRunner run,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SummarizeResultsDialog(
          query: QueryParser.parse('from:russel@jong.com'),
          run: run,
        ),
      ),
    ),
  );
}

void main() {
  group('the dialog never overstates what it read', () {
    testWidgets('a complete summary says so, above the text', (tester) async {
      await _pump(
        tester,
        run:
            (query, {semanticOnly = 0, retrieved = const [], onProgress}) async =>
                _summary(coverage: SummaryCoverage.complete),
      );
      await tester.pumpAndSettle();

      expect(find.text('Summarized all 412 results.'), findsOneWidget);
      // Above, not below: a reader who stops after the first paragraph has
      // still been told what this covers.
      final statement = tester.getRect(
        find.text('Summarized all 412 results.'),
      );
      final body = tester.getRect(
        find.text('They discussed the contract in June.'),
      );
      expect(statement.top, lessThan(body.top));
    });

    testWidgets('a sampled summary never uses the word "all"', (tester) async {
      // The §2e failure, at the surface where it would actually mislead
      // someone. A fluent answer over a truncated read is indistinguishable
      // from a complete one unless this line says otherwise.
      await _pump(
        tester,
        run:
            (query, {semanticOnly = 0, retrieved = const [], onProgress}) async => _summary(
              coverage: SummaryCoverage.sample,
              itemsSummarized: 200,
              matchTotal: 2000,
            ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Summarized the 200 most relevant of about 2000 results.'),
        findsOneWidget,
      );
      expect(find.textContaining('all 2000'), findsNothing);
    });
  });

  testWidgets('progress names the batch, so a slow run is not a frozen one', (
    tester,
  ) async {
    late void Function(SummarizeProgress) report;
    await _pump(
      tester,
      run: (query, {semanticOnly = 0, retrieved = const [], onProgress}) {
        report = onProgress!;
        // Never completes: this is the mid-run state under test.
        return Future.any([]);
      },
    );

    report(
      const SummarizeProgress(
        itemsRead: 412,
        itemsTotal: 412,
        stage: 'Condensing batch 3 of 17',
      ),
    );
    await tester.pump();

    expect(find.text('Condensing batch 3 of 17'), findsOneWidget);
    expect(find.text('412 of 412 results'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('a summarizer that returns nothing says so rather than nothing', (
    tester,
  ) async {
    await _pump(
      tester,
      run: (query, {semanticOnly = 0, retrieved = const [], onProgress}) async => null,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not summarize'), findsOneWidget);
    expect(find.text('Continue in chat'), findsNothing);
  });

  testWidgets('the handoff is only offered once there is something to hand off', (
    tester,
  ) async {
    await _pump(
      tester,
      run:
          (query, {semanticOnly = 0, retrieved = const [], onProgress}) async =>
              _summary(coverage: SummaryCoverage.complete),
    );
    await tester.pumpAndSettle();

    expect(find.text('Continue in chat'), findsOneWidget);
  });

  testWidgets('continuing in chat selects the seeded conversation, then navigates', (
    tester,
  ) async {
    // The bug this replaced: the summary went through the route as `extra` and
    // was read in the chat page's initState, which depended on the route
    // rebuilding that page's State. It did not, so what opened was the
    // previous conversation with none of the summary in it. Selecting a
    // persisted conversation through the notifier the drawer already uses does
    // not depend on any of that.
    AichatPage.selectConversationId.value = 'a-previous-conversation';
    ResultSetSummary? handedOff;

    // Shown with showDialog, the way the search page shows it. Mounting it as
    // a page body instead makes the dialog's own `pop` tear down the route,
    // which is a property of the test rig rather than of the widget.
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder:
              (context, state) => Scaffold(
                body: Builder(
                  builder:
                      (inner) => TextButton(
                        onPressed:
                            () => showDialog<void>(
                              context: inner,
                              builder:
                                  (_) => SummarizeResultsDialog(
                                    query: QueryParser.parse(
                                      'from:russel@jong.com',
                                    ),
                                    run:
                                        (
                                          query, {
                                          semanticOnly = 0,
                                          retrieved = const [],
                                          onProgress,
                                        }) async => _summary(
                                          coverage: SummaryCoverage.complete,
                                        ),
                                    handoff: (query, summary) async {
                                      handedOff = summary;
                                      return 'new-conversation-id';
                                    },
                                  ),
                            ),
                        child: const Text('open'),
                      ),
                ),
              ),
        ),
        GoRoute(
          path: '/aichat',
          builder: (context, state) => const Scaffold(body: Text('chat page')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in chat'));
    await tester.pumpAndSettle();

    expect(handedOff?.text, 'They discussed the contract in June.');
    expect(AichatPage.selectConversationId.value, 'new-conversation-id');
    expect(find.text('chat page'), findsOneWidget);
  });

  testWidgets('the semantic count reaches the summarizer', (tester) async {
    // It is what decides whether the answer may claim completeness, so a
    // dialog that forgot to pass it would produce confidently wrong claims
    // with nothing visibly broken.
    int? seen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SummarizeResultsDialog(
            query: QueryParser.parse('dogs'),
            semanticOnly: 7,
            run: (query, {semanticOnly = 0, retrieved = const [], onProgress}) async {
              seen = semanticOnly;
              return _summary(coverage: SummaryCoverage.sample);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(seen, 7);
  });
}
