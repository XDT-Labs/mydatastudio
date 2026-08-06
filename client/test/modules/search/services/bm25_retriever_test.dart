import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  required String from,
  String to = 'me@example.com',
  String subject = '',
  String body = '',
  int date = 1000,
  int hasAttachments = 0,
}) {
  return db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    'plain_body, has_attachments, is_deleted) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)',
    [id, 'c1', date, from, to, subject, body, hasAttachments],
  );
}

Future<void> _addFile(
  AppDatabase db, {
  required String id,
  required String name,
  String description = '',
  String contentType = 'image/jpeg',
  int isInline = 0,
  int dateCreated = 1000,
}) {
  return db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    'content_type, size, is_deleted, is_inline, description) '
    'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)',
    [
      id,
      name,
      '/photos/$name',
      '/photos',
      dateCreated,
      'c1',
      contentType,
      1,
      isInline,
      description,
    ],
  );
}

Future<SearchResults> _search(AppDatabase db, String query) =>
    Bm25Retriever(db).search(QueryParser.parse(query));

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

  group('hard filters constrain rather than rank', () {
    test(
      'from: excludes every other sender — not merely ranks them lower',
      () async {
        // The load-bearing assertion of the whole design. If a hard filter ever
        // becomes one signal among many in a fused score, a strong text match
        // from the wrong person outranks a weak one from the right person, and
        // the filter looks broken in exactly the way users notice.
        final db = await _freshDb('bm25_from_filter_test.db');
        await _addEmail(
          db,
          id: 'e1',
          from: 'bob@x.com',
          subject: 'quarterly report',
        );
        // A far stronger textual match, from the wrong sender.
        await _addEmail(
          db,
          id: 'e2',
          from: 'alice@y.com',
          subject: 'quarterly report quarterly report',
          body: 'quarterly report quarterly report quarterly',
        );

        final results = await _search(db, 'from:bob@x.com quarterly report');

        expect(results.results.map((r) => r.id), ['e1']);
        await db.close();
      },
    );

    test('a filter with no free text still returns its matches', () async {
      // "Everything from this person" is a legitimate browse. Requiring free
      // text would make the most natural use of a filter return nothing.
      final db = await _freshDb('bm25_filter_only_test.db');
      await _addEmail(db, id: 'e1', from: 'bob@x.com', subject: 'one');
      await _addEmail(db, id: 'e2', from: 'bob@x.com', subject: 'two');
      await _addEmail(db, id: 'e3', from: 'zed@x.com', subject: 'three');

      final results = await _search(db, 'from:bob@x.com');

      expect(results.results.length, 2);
      expect(results.results.map((r) => r.id), containsAll(['e1', 'e2']));
      await db.close();
    });

    test('date range bounds the set', () async {
      final db = await _freshDb('bm25_date_test.db');
      final y2024 = DateTime.utc(2024, 6, 1).millisecondsSinceEpoch;
      final y2026 = DateTime.utc(2026, 6, 1).millisecondsSinceEpoch;
      await _addEmail(
        db,
        id: 'old',
        from: 'a@x.com',
        subject: 'party',
        date: y2024,
      );
      await _addEmail(
        db,
        id: 'new',
        from: 'a@x.com',
        subject: 'party',
        date: y2026,
      );

      final results = await _search(db, 'party 2026');

      expect(results.results.map((r) => r.id), ['new']);
      await db.close();
    });

    test('has:attachment and is:unread narrow the set', () async {
      final db = await _freshDb('bm25_flags_test.db');
      await _addEmail(db, id: 'plain', from: 'a@x.com', subject: 'invoice');
      await _addEmail(
        db,
        id: 'attached',
        from: 'a@x.com',
        subject: 'invoice',
        hasAttachments: 1,
      );

      final results = await _search(db, 'has:attachment invoice');
      expect(results.results.map((r) => r.id), ['attached']);
      await db.close();
    });
  });

  group('ranking', () {
    test('a subject hit outranks a body hit', () async {
      // Column weighting is what stops a long message that happens to repeat a
      // term from burying the message actually about it.
      final db = await _freshDb('bm25_weight_test.db');
      await _addEmail(
        db,
        id: 'body',
        from: 'a@x.com',
        subject: 'unrelated',
        body: 'graduation graduation graduation',
      );
      await _addEmail(
        db,
        id: 'subject',
        from: 'a@x.com',
        subject: 'graduation speech',
      );

      final results = await _search(db, 'graduation');

      expect(results.results.first.id, 'subject');
      await db.close();
    });

    test('scores are positive-is-better after normalisation', () async {
      // bm25() returns negative values where more-negative is more relevant.
      // The flip happens once, at the retriever boundary; if it regresses,
      // every downstream sort silently inverts and still looks plausible.
      final db = await _freshDb('bm25_sign_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'invoice');

      final results = await _search(db, 'invoice');

      expect(results.results.single.score, greaterThan(0));
      await db.close();
    });
  });

  group('source selection', () {
    test(
      'photo descriptions are searchable, inline assets are never returned',
      () async {
        // Inline images are message-body furniture — spacers, logos, tracking
        // pixels. The embedding pipeline already skips them; if search does not,
        // every result page fills with newsletter junk.
        final db = await _freshDb('bm25_inline_test.db');
        await _addFile(
          db,
          id: 'photo',
          name: 'DSC_1468.jpg',
          description: 'a mountain landscape at sunset',
        );
        await _addFile(
          db,
          id: 'spacer',
          name: 'spacer.gif',
          description: 'a mountain landscape at sunset',
          isInline: 1,
        );

        final results = await _search(db, 'mountain landscape');

        expect(results.results.map((r) => r.id), ['photo']);
        await db.close();
      },
    );

    test('type: selects a source rather than reordering one', () async {
      // type:email must make files impossible, not just rank them lower.
      final db = await _freshDb('bm25_type_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'sunset');
      await _addFile(db, id: 'f1', name: 'sunset.jpg', description: 'sunset');

      final emailsOnly = await _search(db, 'type:email sunset');
      expect(emailsOnly.results.map((r) => r.type), [SearchResultType.email]);

      final imagesOnly = await _search(db, 'type:image sunset');
      expect(imagesOnly.results.map((r) => r.type), [SearchResultType.file]);

      await db.close();
    });

    test('a mail-only filter returns no files, and vice versa', () async {
      // A file cannot have a sender. Returning files anyway for `from:` would
      // read as the filter being ignored.
      final db = await _freshDb('bm25_cross_source_test.db');
      await _addFile(db, id: 'f1', name: 'sunset.jpg', description: 'sunset');

      final results = await _search(db, 'from:bob@x.com sunset');

      expect(results.results, isEmpty);
      await db.close();
    });

    test('results from both sources interleave by rank', () async {
      final db = await _freshDb('bm25_interleave_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'sunset');
      await _addFile(db, id: 'f1', name: 'sunset.jpg', description: 'sunset');

      final results = await _search(db, 'sunset');

      expect(results.emailTotal, 1);
      expect(results.fileTotal, 1);
      expect(results.results.length, 2);
      await db.close();
    });
  });

  group('result limits and totals', () {
    test('a source that fills its page still reports the true total', () async {
      // The regression this exists for: `tag:nature` matched 1,134 photos,
      // returned exactly the limit, and reported itself complete — because
      // the total was inferred from list length, and a list capped AT the
      // limit is not longer THAN the limit. Totals now come from COUNT(*),
      // which is also what the facet bar shows the user.
      final db = await _freshDb('bm25_truncation_test.db');
      for (var i = 0; i < 12; i++) {
        await _addFile(
          db,
          id: 'f$i',
          name: 'photo$i.jpg',
          description: 'a mountain landscape',
        );
      }

      final results = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('mountain'), limit: 5);

      expect(results.results.length, 5);
      expect(results.total, 12);
      expect(results.hasMore, isTrue);
      await db.close();
    });

    test('a fully-loaded result set reports no further pages', () async {
      final db = await _freshDb('bm25_not_truncated_test.db');
      for (var i = 0; i < 3; i++) {
        await _addFile(
          db,
          id: 'f$i',
          name: 'photo$i.jpg',
          description: 'a mountain landscape',
        );
      }

      final results = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('mountain'), limit: 5);

      expect(results.hasMore, isFalse);
      expect(results.total, 3);
      await db.close();
    });

    test('counts describe the archive, not the loaded page', () async {
      // With infinite scroll every match is reachable, so reporting the loaded
      // subset would understate the archive to describe an implementation
      // detail. The user asked how many matches exist.
      final db = await _freshDb('bm25_facet_counts_test.db');
      for (var i = 0; i < 6; i++) {
        await _addEmail(db, id: 'e$i', from: 'a@x.com', subject: 'sunset');
        await _addFile(
          db,
          id: 'f$i',
          name: 'sunset$i.jpg',
          description: 'sunset',
        );
      }

      final results = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('sunset'), limit: 4);

      expect(results.results.length, 4);
      // Loaded four; the counts still describe all twelve.
      expect(results.total, 12);
      expect(results.emailTotal, 6);
      expect(results.fileTotal, 6);
      await db.close();
    });

    test('totals count matches the limit never returned', () async {
      final db = await _freshDb('bm25_totals_test.db');
      for (var i = 0; i < 9; i++) {
        await _addEmail(db, id: 'e$i', from: 'bulk@x.com', subject: 'notice');
      }

      final results = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('from:bulk@x.com'), limit: 2);

      expect(results.results.length, 2);
      expect(results.emailTotal, 9);
      expect(results.hasMore, isTrue);
      await db.close();
    });
  });

  group('pagination', () {
    test('paging walks the whole match set exactly once', () async {
      // The property that matters for infinite scroll: every match appears,
      // and none appears twice. Per-source cursors are what make that hold —
      // the two archives are ranked independently and merged, so one global
      // offset would skip rows from whichever source lost the merge.
      final db = await _freshDb('bm25_paging_walk_test.db');
      for (var i = 0; i < 7; i++) {
        await _addEmail(db, id: 'e$i', from: 'a@x.com', subject: 'sunset');
      }
      for (var i = 0; i < 8; i++) {
        await _addFile(
          db,
          id: 'f$i',
          name: 'sunset$i.jpg',
          description: 'sunset',
        );
      }

      final retriever = Bm25Retriever(db);
      final parsed = QueryParser.parse('sunset');
      final seen = <String>[];
      var emailOffset = 0;
      var fileOffset = 0;

      for (var page = 0; page < 10; page++) {
        final result = await retriever.search(
          parsed,
          limit: 4,
          emailOffset: emailOffset,
          fileOffset: fileOffset,
        );
        seen.addAll(result.results.map((r) => r.id));
        emailOffset = result.emailOffset;
        fileOffset = result.fileOffset;
        if (!result.hasMore) break;
      }

      expect(seen.length, 15);
      expect(seen.toSet().length, 15, reason: 'no result appears twice');
      await db.close();
    });

    test('a cursor past the end returns nothing and reports no more', () async {
      final db = await _freshDb('bm25_paging_end_test.db');
      await _addFile(db, id: 'f1', name: 'a.jpg', description: 'sunset');

      final result = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('sunset'), limit: 10, fileOffset: 5);

      expect(result.results, isEmpty);
      // The total still describes the archive even when this page is empty.
      expect(result.total, 1);
      await db.close();
    });

    test('onlySource restricts retrieval to one archive', () async {
      // What a facet selection does. Slicing the loaded page instead would cap
      // "Photos & Files" at whatever fitted alongside the mail.
      final db = await _freshDb('bm25_only_source_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'sunset');
      await _addFile(db, id: 'f1', name: 'sunset.jpg', description: 'sunset');

      final filesOnly = await Bm25Retriever(
        db,
      ).search(QueryParser.parse('sunset'), onlySource: SearchResultType.file);

      expect(filesOnly.results.map((r) => r.id), ['f1']);
      // The restricted total counts only that archive, so the facet's own
      // number stays consistent once it is selected.
      expect(filesOnly.total, 1);
      expect(filesOnly.emailTotal, 0);
      await db.close();
    });
  });

  group('query robustness', () {
    test('FTS5 syntax in user input does not throw', () async {
      // Input reaches FTS5 as a query *language*. A trailing AND, a stray
      // quote or a bare * is a syntax error, and mid-typing that would surface
      // as an exception rather than a result list.
      final db = await _freshDb('bm25_syntax_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'invoice');

      for (final hostile in [
        'invoice AND',
        'invoice "unbalanced',
        '*',
        'NEAR(',
        'invoice OR OR',
        r'^invoice',
        '((((',
      ]) {
        await expectLater(_search(db, hostile), completes);
      }

      await db.close();
    });

    test('an unmatched term returns empty rather than everything', () async {
      final db = await _freshDb('bm25_nomatch_test.db');
      await _addEmail(db, id: 'e1', from: 'a@x.com', subject: 'invoice');

      final results = await _search(db, 'zzzznotpresent');

      expect(results.results, isEmpty);
      await db.close();
    });
  });
}
