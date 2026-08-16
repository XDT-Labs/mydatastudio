import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/result_set_summarizer.dart';
import 'package:mydatastudio/repositories/aichat_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Real database, real retriever, fake model.
///
/// The model is the only thing stubbed, because it is the only part whose
/// output cannot be asserted. Everything this file is actually about —
/// which items reach which batch, whether the set was read to the end, and
/// what the answer is then allowed to claim about itself — is real code.
final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

Future<void> _addEmail(
  AppDatabase db, {
  required String id,
  String from = 'russel@jong.com',
  String subject = 'hello',
  String body = 'a message body',
  int date = 1000,
}) {
  return db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    'plain_body, body_text, has_attachments, is_deleted) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0)',
    [id, 'c1', date, from, 'me@example.com', subject, body, body],
  );
}

/// A body long enough that 25 of these exceed [maxSinglePassChars], forcing
/// the batching path. Short fixtures now take the single-pass path instead,
/// which is the point of that branch — but the batching tests still need to
/// reach the batching code.
final _bulkBody = List.filled(200, 'lorem ipsum dolor sit amet').join(' ');

/// Records every prompt it is asked to complete, and answers predictably.
class _FakeModel {
  _FakeModel({this.replyPadding = 0});

  final prompts = <String>[];
  String? failOnPromptContaining;

  /// Characters of filler appended to each reply, for exercising the size
  /// budgets. The identifying prefix stays at the front so a padded reply can
  /// still be traced through the reduce passes.
  final int replyPadding;

  Future<String?> call(String prompt) async {
    prompts.add(prompt);
    final trip = failOnPromptContaining;
    if (trip != null && prompt.contains(trip)) return null;
    return 'summary-of-${prompts.length}${'x' * replyPadding}';
  }

  /// Prompts that condensed a batch, as opposed to the final merge.
  List<String> get mapPrompts =>
      prompts.where((p) => !p.startsWith('Below are')).toList();

  List<String> get reducePrompts =>
      prompts.where((p) => p.startsWith('Below are')).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => '.');
  });

  tearDownAll(() {
    for (final path in _createdDbs) {
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = io.File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    }
    _createdDbs.clear();
  });

  group('coverage — what the answer is allowed to claim', () {
    test('a fully-read filtered set may say "all"', () async {
      // The claim §2e exists to make sayable. A hard filter gives a known
      // denominator and every counted row is reachable by paging, so reading
      // to the end really is reading all of them.
      final db = await _freshDb('summarize_complete_test.db');
      for (var i = 0; i < 8; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i');
      }
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(summary!.coverage, SummaryCoverage.complete);
      expect(summary.matchTotal, 8);
      expect(summary.itemsSummarized, 8);
      expect(summary.coverageStatement, 'Summarized all 8 results.');
      await db.close();
    });

    test('a semantic contribution makes it a sample, however much was read', () {
      // The trap this guards. Every lexical row can be read to the end and the
      // set still not be complete: the results on screen also hold hits no
      // keyword matched, and those came from a top-K vector scan that has no
      // denominator to be complete against. Paging this retriever forever
      // would never reach them, so "all" would be a lie told with a correct
      // number attached to it.
      return _freshDb('summarize_semantic_test.db').then((db) async {
        for (var i = 0; i < 4; i++) {
          await _addEmail(db, id: 'e$i', subject: 'note $i');
        }
        final model = _FakeModel();

        final summary = await ResultSetSummarizer(
          db: db,
          complete: model.call,
        ).summarize(
          QueryParser.parse('from:russel@jong.com'),
          semanticOnly: 3,
        );

        expect(summary!.coverage, SummaryCoverage.sample);
        expect(summary.coverageStatement, contains('most relevant of about'));
        expect(summary.coverageStatement, isNot(contains('all')));
        await db.close();
      });
    });

    test('the ceiling downgrades the claim rather than silently binding', () async {
      // maxItems is what stops one click becoming an hours-long job on a
      // 200k-message archive. It is only honest if crossing it changes what
      // the summary says about itself — otherwise a truncated read is
      // indistinguishable from a complete one.
      final db = await _freshDb('summarize_ceiling_test.db');
      final count = ResultSetSummarizer.maxItems + 5;
      for (var i = 0; i < count; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i');
      }
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(summary!.itemsSummarized, ResultSetSummarizer.maxItems);
      expect(summary.matchTotal, count);
      expect(summary.coverage, SummaryCoverage.sample);
      await db.close();
    });
  });

  group('map-reduce', () {
    test('every item reaches exactly one batch, and none is dropped', () async {
      // The invariant the whole approach rests on. A batching bug here does
      // not throw and does not look wrong — it produces a confident summary
      // with a handful of messages quietly missing from it.
      final db = await _freshDb('summarize_batching_test.db');
      const count = 60; // 3 batches at a batch size of 25
      for (var i = 0; i < count; i++) {
        await _addEmail(db, id: 'e$i', subject: 'unique-subject-$i', body: _bulkBody);
      }
      final model = _FakeModel();

      await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      final joined = model.mapPrompts.join('\n');
      for (var i = 0; i < count; i++) {
        expect(
          RegExp('unique-subject-$i"').allMatches(joined).length,
          1,
          reason: 'e$i must appear in exactly one batch',
        );
      }
      expect(model.mapPrompts, hasLength(3));
      await db.close();
    });

    test('one batch is not followed by a pointless merge', () async {
      // A reduce over a single part cannot add anything, and on a local model
      // it is a second slow inference call for a paraphrase.
      final db = await _freshDb('summarize_single_batch_test.db');
      for (var i = 0; i < 5; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i');
      }
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(model.reducePrompts, isEmpty);
      expect(model.prompts, hasLength(1));
      expect(summary!.text, 'summary-of-1');
      await db.close();
    });

    test('several batches are merged, and the merge is what is returned', () async {
      final db = await _freshDb('summarize_reduce_test.db');
      for (var i = 0; i < 60; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i', body: _bulkBody);
      }
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(model.reducePrompts, hasLength(1));
      // The merge sees the batch summaries, not the raw messages again.
      expect(model.reducePrompts.single, contains('summary-of-1'));
      expect(model.reducePrompts.single, contains('summary-of-3'));
      expect(summary!.text, 'summary-of-4');
      expect(summary.batches, 3);
      await db.close();
    });

    test('a batch the model drops downgrades the claim', () async {
      // Failing loud, in the only currency this function has. The set was read
      // completely, so the coverage arithmetic alone would still say
      // "complete" — but a summary missing a third of its input is not one,
      // and returning what did come back is more useful than returning null.
      final db = await _freshDb('summarize_failed_batch_test.db');
      for (var i = 0; i < 60; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i', body: _bulkBody);
      }
      final model = _FakeModel()..failOnPromptContaining = 'results 51-60';

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(summary!.coverage, SummaryCoverage.sample);
      expect(summary.text, 'summary-of-1\n\nsummary-of-2');
      expect(model.reducePrompts, isEmpty, reason: 'nothing to merge onto');
      await db.close();
    });

    test('results the lexical pass cannot reach are summarized anyway', () async {
      // Found in the app, not here. "Summarize these results" means the set on
      // screen, and rebuilding it from BM25 gives a different one whenever
      // free text is involved: the lexical count is `FTS MATCH ? AND filter`,
      // so a fused search showing 18 emails left this summarizing the 3 that
      // happened to contain the query's words — and calling it "all 3".
      final db = await _freshDb('summarize_onscreen_test.db');
      await _addEmail(db, id: 'e1', subject: 'kayaking on the lake');
      final model = _FakeModel();

      await _addEmail(db, id: 'e2', subject: 'vector only one');
      await _addEmail(db, id: 'e3', subject: 'vector only two');

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(
        // Lexically this reaches e1 alone.
        QueryParser.parse('from:russel@jong.com kayaking'),
        retrieved: const [
          SearchResult(
            id: 'e1',
            type: SearchResultType.email,
            title: 'kayaking on the lake',
            score: 1.0,
          ),
          SearchResult(
            id: 'e2',
            type: SearchResultType.email,
            title: 'vector only one',
            score: 0.9,
          ),
          SearchResult(
            id: 'e3',
            type: SearchResultType.email,
            title: 'vector only two',
            score: 0.8,
          ),
        ],
      );

      expect(summary, isNotNull);
      expect(summary!.itemsSummarized, 3);
      // e1 came from both paths and must appear once, not twice.
      final prompt = model.mapPrompts.single;
      expect('kayaking on the lake"'.allMatches(prompt).length, 1);
      expect(prompt, contains('vector only one'));
      expect(prompt, contains('vector only two'));
      // Rows paging cannot enumerate mean the denominator is gone with them.
      expect(summary.coverage, SummaryCoverage.sample);
      await db.close();
    });

    test('an empty result set summarizes to nothing, not to an empty answer', () async {
      // A summary of no messages that reads like a summary is worse than no
      // summary: it invites the user to believe the archive holds nothing.
      final db = await _freshDb('summarize_empty_test.db');
      await _addEmail(db, id: 'e1', from: 'someone@else.com');
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:nobody@nowhere.com'));

      expect(summary, isNull);
      expect(model.prompts, isEmpty, reason: 'no inference on an empty set');
      await db.close();
    });
  });

  group('one prompt when one prompt is enough', () {
    test('a set that fits is summarized directly, with no batching', () async {
      // Map-reduce works around a context window; it is not an improvement on
      // reading the text. Condensing 18 emails that would have fit costs an
      // extra call and makes the answer a summary of a summary.
      final db = await _freshDb('summarize_single_pass_test.db');
      for (var i = 0; i < 18; i++) {
        await _addEmail(db, id: 'e$i', subject: 'topic $i');
      }
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(model.prompts, hasLength(1), reason: 'one call, not two');
      expect(model.prompts.single, startsWith('These are all 18 results'));
      expect(model.prompts.single, isNot(contains('will be combined')));
      for (var i = 0; i < 18; i++) {
        expect(model.prompts.single, contains('topic $i'));
      }
      expect(summary!.batches, 1);
      expect(summary.parts, isEmpty, reason: 'nothing was condensed');
      await db.close();
    });

    test('a set too large for one prompt still batches', () async {
      final db = await _freshDb('summarize_still_batches_test.db');
      for (var i = 0; i < 30; i++) {
        await _addEmail(db, id: 'e$i', subject: 'topic $i', body: _bulkBody);
      }
      final model = _FakeModel();

      await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(model.mapPrompts.first, contains('will be combined'));
      expect(model.prompts.length, greaterThan(1));
      await db.close();
    });

    test('the single-pass summary still carries its sources to chat', () async {
      // The reason this branch is safe to take: skipping the condensation
      // loses nothing, because the handoff was going to send the source text
      // rather than the condensation anyway.
      final db = await _freshDb('summarize_single_pass_sources_test.db');
      await _addEmail(db, id: 'e1', subject: 'the technical question');
      final model = _FakeModel();

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(summary!.sources, hasLength(1));
      expect(summary.sources.single, contains('the technical question'));
      await db.close();
    });
  });

  group('size budgets — measured, not guessed', () {
    test('the map prompt states a character budget', () async {
      // Without one the model answered a 25-message batch with 6,281
      // characters — ~1,570 generated tokens, which is where 2m14s per batch
      // came from. Generation dominates, so the length of the reply is the
      // speed of the feature.
      final db = await _freshDb('summarize_budget_prompt_test.db');
      for (var i = 0; i < 30; i++) {
        await _addEmail(db, id: 'e$i', body: _bulkBody);
      }
      final model = _FakeModel();

      await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      expect(
        model.mapPrompts.first,
        contains(
          'under ${ResultSetSummarizer.maxCondensationChars} characters',
        ),
      );
      await db.close();
    });

    test('an over-long condensation is trimmed rather than trusted', () async {
      // The budget is stated in the prompt, and a prompt is a request. A model
      // that ignores it would put the reduce back over the context window,
      // which is the failure this budget exists to prevent.
      final db = await _freshDb('summarize_clip_test.db');
      for (var i = 0; i < 30; i++) {
        await _addEmail(db, id: 'e$i', body: _bulkBody);
      }

      final summary = await ResultSetSummarizer(
        db: db,
        complete: _FakeModel(replyPadding: 9000).call,
      ).summarize(QueryParser.parse('from:russel@jong.com'));

      for (final part in summary!.parts) {
        expect(
          part.length,
          lessThanOrEqualTo(ResultSetSummarizer.maxCondensationChars + 1),
        );
      }
      // The final answer has its own, larger budget — it is what gets read,
      // not an intermediate that has to survive a merge.
      expect(
        summary.text.length,
        lessThanOrEqualTo(ResultSetSummarizer.maxSummaryChars + 1),
      );
      await db.close();
    });
  });

  group('groupByPromptBudget', () {
    List<List<int>> group(List<int> sizes, int budget) =>
        ResultSetSummarizer.groupByPromptBudget(sizes, budget);

    test('packs parts up to the budget', () {
      expect(group([30, 30, 30, 30], 100), [
        [0, 1, 2],
        [3],
      ]);
    });

    test('every part lands in exactly one group', () {
      final groups = group([10, 40, 35, 20, 50, 15], 60);
      final seen = [for (final g in groups) ...g]..sort();
      expect(seen, [0, 1, 2, 3, 4, 5]);
    });

    test('a part larger than the budget travels alone rather than being split', () {
      // A summary cut in half and merged with someone else's half is worse
      // than one oversized prompt the model truncates at the end — the first
      // reads as complete and is not.
      final groups = group([10, 500, 10], 100);
      expect(groups, [
        [0],
        [1],
        [2],
      ]);
    });

    test('one group is the terminating case', () {
      expect(group([10, 10], 100), [
        [0, 1],
      ]);
    });
  });

  group('the reduce recurses instead of overflowing', () {
    test('too many parts for one prompt are merged in passes', () async {
      // The failure this fixes: 17 batches of unbudgeted output was ~107k
      // characters against a 32,768-token window — and 17 batches is exactly
      // the "summarize all 412 messages" case the feature exists for.
      final db = await _freshDb('summarize_recursive_test.db');
      const count = 425; // 17 batches at a batch size of 25
      for (var i = 0; i < count; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i', body: _bulkBody);
      }
      // Padded so each condensation clips to the full 2,400 characters:
      // 17 x 2,400 exceeds the 40,000-character reduce budget.
      final model = _FakeModel(replyPadding: 4000);
      final stages = <String>[];

      final summary = await ResultSetSummarizer(
        db: db,
        complete: model.call,
      ).summarize(
        QueryParser.parse('from:russel@jong.com'),
        onProgress: (p) => stages.add(p.stage),
      );

      // More than one merge happened, and none of them was oversized.
      expect(model.reducePrompts.length, greaterThan(1));
      for (final prompt in model.reducePrompts) {
        expect(
          prompt.length,
          lessThan(ResultSetSummarizer.maxReducePromptChars * 2),
        );
      }
      expect(stages, contains(predicate<String>((s) => s.contains('groups'))));

      // Completeness is the whole point: every batch summary must reach some
      // merge. Dropping parts to fit would have been the easy fix and would
      // silently remove messages from a summary that claims to cover them.
      final merged = model.reducePrompts.join('\n');
      for (var i = 1; i <= 17; i++) {
        expect(
          merged,
          contains('summary-of-$i'),
          reason: 'batch $i must reach a merge',
        );
      }
      expect(summary!.parts, hasLength(17));
      await db.close();
    });
  });

  group('the chat handoff', () {
    test('seeds a conversation as a request and an answer', () async {
      // Not a prefilled composer. That made it read as though the user had
      // typed a summary of their own archive and left the model to guess what
      // to do with it; a user turn followed by an assistant turn is simply
      // what a finished exchange looks like.
      final db = await _freshDb('summarize_handoff_test.db');
      final id = await SummaryChatHandoff(AichatRepository(db)).create(
        QueryParser.parse('from:russel@jong.com'),
        const ResultSetSummary(
          text: 'They discussed the contract.',
          coverage: SummaryCoverage.complete,
          itemsSummarized: 412,
          matchTotal: 412,
          batches: 17,
        ),
      );

      final messages = await AichatRepository(db).getMessages(id);
      expect(messages.map((m) => m.role), ['user', 'assistant']);
      expect(messages.first.content, contains('from:russel@jong.com'));
      // The coverage sentence has to survive into the history. Once this is a
      // conversation it is the only thing left saying whether the summary is
      // of everything or of a slice.
      expect(messages.last.content, contains('Summarized all 412 results.'));
      expect(messages.last.content, contains('They discussed the contract.'));
      await db.close();
    });

    test('carries the results themselves when they fit', () async {
      // The point the summary alone cannot serve. "What was the technical
      // question, and what was the answer" is not in a summary — reducing
      // threw it away, which is what reducing is. 18 emails fit a 32k-token
      // window comfortably, so making the model work from the compressed
      // version is a loss taken for nothing.
      final db = await _freshDb('summarize_handoff_sources_test.db');
      final id = await SummaryChatHandoff(AichatRepository(db)).create(
        QueryParser.parse('russell jong'),
        const ResultSetSummary(
          text: 'Overall summary.',
          coverage: SummaryCoverage.sample,
          itemsSummarized: 18,
          matchTotal: 18,
          batches: 1,
          parts: ['the condensed version'],
          sources: ['[1] the actual email text'],
        ),
      );

      final messages = await AichatRepository(db).getMessages(id);
      // Role `system`: the model reads it, the transcript does not show it.
      expect(messages.map((m) => m.role), ['user', 'assistant', 'system']);
      expect(messages.last.content, contains('the actual email text'));
      expect(messages.last.content, contains('the results themselves'));
      await db.close();
    });

    test('falls back to batch summaries when the sources do not fit', () async {
      final db = await _freshDb('summarize_handoff_fallback_test.db');
      final id = await SummaryChatHandoff(AichatRepository(db)).create(
        QueryParser.parse('russell jong'),
        ResultSetSummary(
          text: 'Overall summary.',
          coverage: SummaryCoverage.complete,
          itemsSummarized: 412,
          matchTotal: 412,
          batches: 17,
          parts: const ['batch one', 'batch two'],
          sources: ['x' * (SummaryChatHandoff.maxDetailChars + 1)],
        ),
      );

      final messages = await AichatRepository(db).getMessages(id);
      expect(messages.last.role, 'system');
      expect(messages.last.content, contains('batch one'));
      expect(messages.last.content, contains('condensed notes'));
      await db.close();
    });

    test('carries the batch summaries, because reducing is lossy', () async {
      final db = await _freshDb('summarize_handoff_detail_test.db');
      final id = await SummaryChatHandoff(AichatRepository(db)).create(
        QueryParser.parse('from:russel@jong.com'),
        const ResultSetSummary(
          text: 'Overall summary.',
          coverage: SummaryCoverage.complete,
          itemsSummarized: 50,
          matchTotal: 50,
          batches: 2,
          parts: ['batch one detail', 'batch two detail'],
        ),
      );

      final messages = await AichatRepository(db).getMessages(id);
      expect(messages, hasLength(3));
      expect(messages.last.content, contains('batch one detail'));
      expect(messages.last.content, contains('batch two detail'));
      await db.close();
    });

    test('detail too large for the window is dropped, not truncated', () async {
      // Half a batch summary is detail that reads as complete and is not —
      // the same dishonesty the coverage flag exists to prevent, one level
      // down.
      final db = await _freshDb('summarize_handoff_budget_test.db');
      final huge = 'z' * SummaryChatHandoff.maxDetailChars;
      final id = await SummaryChatHandoff(AichatRepository(db)).create(
        QueryParser.parse('from:russel@jong.com'),
        ResultSetSummary(
          text: 'Overall summary.',
          coverage: SummaryCoverage.complete,
          itemsSummarized: 50,
          matchTotal: 50,
          batches: 2,
          parts: [huge, huge],
        ),
      );

      final messages = await AichatRepository(db).getMessages(id);
      expect(messages, hasLength(2), reason: 'summary kept, detail dropped');
      await db.close();
    });
  });

  group('progress', () {
    test('reports the batch it is on, so a long run is not a frozen one', () async {
      final db = await _freshDb('summarize_progress_test.db');
      for (var i = 0; i < 60; i++) {
        await _addEmail(db, id: 'e$i', subject: 'note $i', body: _bulkBody);
      }
      final stages = <String>[];

      await ResultSetSummarizer(db: db, complete: _FakeModel().call).summarize(
        QueryParser.parse('from:russel@jong.com'),
        onProgress: (p) => stages.add(p.stage),
      );

      expect(stages, contains('Reading results'));
      expect(stages, contains('Condensing batch 1 of 3'));
      expect(stages, contains('Condensing batch 3 of 3'));
      expect(stages.last, 'Combining 3 batch summaries');
      await db.close();
    });
  });
}
