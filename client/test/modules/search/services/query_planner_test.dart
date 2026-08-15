import 'dart:async';
import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/query_planner.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The one place a model is allowed to influence search.
///
/// Everything here is about keeping that influence small enough to be safe:
/// it may reorder, never filter; it may fill a silence, never overrule the
/// user; and every way it can fail has to end in the results the user already
/// had. The model itself is stubbed, because what it answers is not what these
/// tests are about — what the app does with the answer is.
const _dim = 2048;
final _createdDbs = <String>[];
final _recent = DateTime.utc(2026, 1, 1).millisecondsSinceEpoch;

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

List<double> _vector(int axis, {double lean = 1.0}) {
  final v = List<double>.filled(_dim, 0.0);
  v[axis] = lean;
  v[(axis + 1) % _dim] = math.sqrt(1 - lean * lean);
  return v;
}

/// A photo the words cannot reach, and a mail that both retrievers find.
///
/// The mail is double-listed — lexical *and* vector — which is the case §15f
/// documents as the one a modality preference has to be able to overcome. The
/// query used against it names no kind of thing, so the parser has nothing to
/// strip and correctly states no preference. That silence is the planner's
/// entire reason to exist.
Future<AppDatabase> _archiveOfBoth(String dbName) async {
  final db = await _freshDb(dbName);
  await db.rawDb.execute(
    "INSERT OR REPLACE INTO collections (id, name, path, type, scanner, "
    "scan_status) VALUES ('c1', 'c1', '/', 'files', 'file.local', 'idle')",
  );
  await db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    "content_type, size, is_deleted, is_inline, is_favorite, description) "
    "VALUES ('photo', 'IMG_2201.jpg', '/p/IMG_2201.jpg', '/p', ?, 'c1', "
    "'image/jpeg', 1, 0, 0, 0, 'a family standing together outdoors')",
    [_recent],
  );
  await db.rawDb.execute(
    'INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding) '
    "VALUES ('photo', 'file', vector_as_f32(?))",
    ['[${_vector(0, lean: 0.8).join(',')}]'],
  );
  await db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    "plain_body, has_attachments, is_deleted) VALUES ('m1', 'c1', ?, "
    "'aunt@x.com', 'me@x.com', 'the family reunion', "
    "'notes from the family reunion', 0, 0)",
    [_recent],
  );
  await db.rawDb.execute(
    'INSERT INTO emails_embeddings (email_id, qwen3_vl_embedding) '
    'VALUES (?, vector_as_f32(?))',
    ['m1', '[${_vector(0).join(',')}]'],
  );
  return db;
}

SearchService _service(String? plannerReply) {
  return SearchService()
    ..embedder = ((_) async => _vector(0))
    ..planner = QueryPlanner(transport: (_) async => plannerReply);
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

  group('when the model is asked at all', () {
    test('never, when the query already named a kind', () async {
      // "family photos" answers this question itself, and an inferred
      // preference that contradicts a stated one is strictly worse than no
      // inference. The model is not consulted, so it cannot disagree.
      var asked = false;
      final planner = QueryPlanner(
        transport: (_) async {
          asked = true;
          return '{"modalities": ["email"]}';
        },
      );

      final plan = await planner.plan(QueryParser.parse('family photos'));

      expect(plan, isNull);
      expect(asked, isFalse);
    });

    test('never, when the user typed an explicit type:', () async {
      var asked = false;
      final planner = QueryPlanner(
        transport: (_) async {
          asked = true;
          return '{"modalities": ["email"]}';
        },
      );

      final plan = await planner.plan(QueryParser.parse('type:image dog'));

      expect(plan, isNull);
      expect(asked, isFalse);
    });

    test('never, for a query that is only filters', () async {
      // `from:mike after:2026` is a browse. There is nothing to reorder by
      // meaning, and a round trip to a language model to learn that is a
      // second of latency spent on nothing.
      var asked = false;
      final planner = QueryPlanner(
        transport: (_) async {
          asked = true;
          return '{"modalities": ["email"]}';
        },
      );

      final plan = await planner.plan(
        QueryParser.parse('from:mike@x.com after:2026'),
      );

      expect(plan, isNull);
      expect(asked, isFalse);
    });

    test('yes, when the query named nothing', () async {
      // The case with no deterministic answer: the archive could hold a
      // graduation speech as a video, a document, or an attachment on mail,
      // and there is no word in the query to key on.
      final planner = QueryPlanner(
        transport: (_) async => '{"modalities": ["document"]}',
      );

      expect(
        await planner.plan(QueryParser.parse('graduation speech')),
        isNotNull,
      );
    });

    test('the filters are never sent to the model', () async {
      // A resolved query carries an email address the user typed a name for.
      // The model has no use for it — it cannot emit a filter — so sending it
      // would hand an inference engine a contact for nothing in return.
      String? seen;
      final planner = QueryPlanner(
        transport: (prompt) async {
          seen = prompt;
          return '{"modalities": ["email"]}';
        },
      );

      await planner.plan(QueryParser.parse('from:russel@jong.com contract'));

      expect(seen, isNotNull);
      expect(seen, contains('contract'));
      expect(seen, isNot(contains('russel@jong.com')));
    });
  });

  group('reading the answer', () {
    Future<Set<String>?> planFor(String reply) {
      return QueryPlanner(
        transport: (_) async => reply,
      ).plan(QueryParser.parse('graduation speech'));
    }

    test("the model's word becomes the app's word", () async {
      // `photo` is what the model is asked to say and `image` is what a result
      // calls itself. A preference the results cannot be compared against is
      // silently no preference at all — it would boost nothing and look like
      // the feature simply not working.
      expect(await planFor('{"modalities": ["photo"]}'), {'image'});
    });

    test('document covers what the archive never classified', () async {
      // `modality` collapses Word, text and everything else into `file`.
      // Preferring only `pdf` would lift the PDFs of a document search and
      // leave the .docx behind it.
      expect(await planFor('{"modalities": ["document"]}'), {'pdf', 'file'});
    });

    test('naming every kind is the same as naming none', () async {
      // An answer that prefers everything expresses no preference, and
      // applying it costs a page reorder to arrive at the same order. Measured
      // on gemma4:12b, an earlier prompt returned exactly this for 5 of 10
      // queries.
      expect(
        await planFor(
          '{"modalities": ["photo", "video", "email", "document"]}',
        ),
        isNull,
      );
    });

    test('a word outside the vocabulary means the grammar did not hold', () async {
      // Not a value to salvage. If the answer is outside the enum then the
      // constrained decoding was not applied, and nothing else in the reply
      // can be trusted either.
      expect(await planFor('{"modalities": ["spreadsheet"]}'), isNull);
    });

    test('a fenced answer is still an answer', () async {
      // llama.cpp does not reliably apply the grammar across handlers, and the
      // model falls back to its habit of wrapping JSON in a code block.
      expect(
        await planFor('```json\n{"modalities": ["photo"]}\n```'),
        {'image'},
      );
    });

    test('every failure is silence, not an error', () async {
      // Search must never be worse for having asked. There is no error path
      // out of the planner — a wedged subprocess, a truncated reply and a
      // model that answered in prose all leave the user with the results they
      // already had.
      expect(await planFor('not json at all'), isNull);
      expect(await planFor('{"modalities": '), isNull);
      expect(await planFor('{"modalities": []}'), isNull);
      expect(await planFor('{"something_else": ["photo"]}'), isNull);
      expect(
        await QueryPlanner(
          transport: (_) async => null,
        ).plan(QueryParser.parse('graduation speech')),
        isNull,
      );
    });
  });

  group('what the answer does to the results', () {
    test('a photo query led by mail is reordered once the plan lands', () async {
      // The failure this phase exists to fix. "family reunion" names no kind,
      // so nothing states a preference; the mail matches both retrievers and
      // RRF adds both contributions, while the photograph — which is what the
      // user meant — is reachable only by vector and loses. The model supplies
      // the one word the parser had no way to infer.
      final db = await _archiveOfBoth('planner_reorder_test.db');
      final service = _service('{"modalities": ["photo"]}');

      final before = await service.invoke(SearchCommand('family reunion', db));
      expect(before.results.first.id, 'm1', reason: 'mail leads on its own');

      await service.refinement;

      expect(service.sink.value.results.first.id, 'photo');
      await db.close();
    });

    test('the refinement reorders and never re-selects', () async {
      // The hard boundary on what a model is allowed to do here. It answers
      // with modality words and they become a score multiplier — there is no
      // path from its answer to a WHERE clause, so a wrong answer costs order
      // and cannot cost a result.
      final db = await _freshDb('planner_membership_test.db');
      await db.rawDb.execute(
        "INSERT OR REPLACE INTO collections (id, name, path, type, scanner, "
        "scan_status) VALUES ('c1', 'c1', '/', 'files', 'file.local', 'idle')",
      );
      for (var i = 0; i < 4; i++) {
        await db.rawDb.execute(
          'INSERT INTO files (id, name, path, parent, date_created, '
          'collection_id, content_type, size, is_deleted, is_inline, '
          "is_favorite, description) VALUES (?, ?, ?, '/p', ?, 'c1', "
          "'image/jpeg', 1, 0, 0, 0, 'reunion')",
          ['f$i', 'IMG_$i.jpg', '/p/IMG_$i.jpg', _recent],
        );
      }
      await db.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
        "plain_body, has_attachments, is_deleted) VALUES ('m1', 'c1', ?, "
        "'aunt@x.com', 'me@x.com', 'the reunion', 'reunion notes', 0, 0)",
        [_recent],
      );
      final service = _service('{"modalities": ["email"]}');

      final before = await service.invoke(SearchCommand('reunion', db));
      final beforeIds = before.results.map((r) => r.id).toSet();
      await service.refinement;

      expect(service.sink.value.results.map((r) => r.id).toSet(), beforeIds);
      await db.close();
    });

    test('an answer to the previous query is thrown away', () async {
      // The model takes about a second, which is long enough for the user to
      // have typed something else. Applying it then would order one query's
      // results by another query's meaning — and it would look exactly like a
      // random reshuffle, because that is what it would be.
      //
      // The plan is held open deliberately: a stub that answers immediately
      // resolves before the second search is even issued, and would let this
      // pass without the staleness guard existing at all.
      final db = await _archiveOfBoth('planner_stale_test.db');
      final held = Completer<String?>();
      final service =
          SearchService()
            ..embedder = ((_) async => _vector(0))
            ..planner = QueryPlanner(transport: (_) async => held.future);

      await service.invoke(SearchCommand('family reunion', db));
      final stale = service.refinement;

      // The second query names its own kind, so it asks the model nothing —
      // leaving the first query's answer as the only one still in flight.
      await service.invoke(SearchCommand('reunion emails', db));
      final current = service.sink.value.results.map((r) => r.id).toList();
      expect(current.first, 'm1', reason: 'the stated preference applied');

      held.complete('{"modalities": ["photo"]}');
      await stale;

      expect(service.sink.value.results.map((r) => r.id).toList(), current);
      // The published order is the weaker half of this. `lastQuery` is what
      // paging, the facets and the summarize handoff all read, so a stale plan
      // landing in it would keep contradicting the current query long after
      // the reorder that produced it.
      expect(
        service.lastQuery!.preferredTypes,
        {'email'},
        reason: "a stale plan must not overwrite the query's own preference",
      );
      await db.close();
    });

    test('a lexical-only search is left alone', () async {
      // With no AI subprocess there is no fused list, and order comes from
      // pages of SQL. Reordering the first page would leave the list
      // disagreeing with its own tail — a result the user scrolled past
      // reappearing below.
      final db = await _archiveOfBoth('planner_lexical_test.db');
      final service =
          SearchService()
            ..embedder = ((_) async => null)
            ..planner = QueryPlanner(
              transport: (_) async => '{"modalities": ["photo"]}',
            );

      final before = await service.invoke(SearchCommand('family reunion', db));
      await service.refinement;

      expect(
        service.sink.value.results.map((r) => r.id).toList(),
        before.results.map((r) => r.id).toList(),
      );
      await db.close();
    });
  });
}
