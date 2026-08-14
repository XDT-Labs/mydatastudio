// Document chunks reaching retrieval — search plan §18f, Phase 7 step 3.
//
// Three behaviours, each of which fails by looking like success: a chunk hit
// that forgets which chunk won (the footnote silently cites nothing), a
// document that reaches fusion as one row per matching passage (RRF reads one
// file as many corroborating results), and a total that counts a file its own
// results page will show only once.
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/bm25_retriever.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '.');
  });

  late AppDatabase db;

  Future<void> open(String dbName) async {
    final supportDir = await getApplicationSupportDirectory();
    final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
    if (dbFile.existsSync()) dbFile.deleteSync();
    db = await AppDatabase.create(null, supportDir.path, dbName);
    await db.rawDb.execute(
      "INSERT INTO collections (id, name, path, type, scanner, scan_status) "
      "VALUES ('col-1', 'Docs', '/tmp', 'files', 'local', 'idle')",
    );
  }

  Future<void> addFile(String id, String name) async {
    await db.rawDb.execute(
      'INSERT INTO files (id, collection_id, name, path, parent, '
      'content_type, size, date_created, date_last_modified) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, 'col-1', name, '/tmp/$name', '/tmp', 'application/pdf', 100, 0, 0],
    );
  }

  Future<void> addChunk(String fileId, int index, String text, {int? page}) async {
    await db.rawDb.execute(
      'INSERT INTO file_chunks (file_id, chunk_index, page, text, '
      'model_version) VALUES (?, ?, ?, ?, ?)',
      [fileId, index, page, text, 'test-model'],
    );
  }

  tearDown(() async => db.close());

  ParsedQuery parse(String text) => QueryParser.parse(text);

  group('lexical retrieval over chunk text', () {
    test('finds a document by words that appear only inside it', () async {
      await open('doc_retrieval_text_test.db');
      await addFile('f1', 'commencement.pdf');
      await addChunk('f1', 0, 'the graduation speech I gave in 2019', page: 3);

      final results = await Bm25Retriever(db).search(parse('graduation'));

      expect(results.results.map((r) => r.id), ['f1'],
          reason: 'the filename contains none of the query words');
    });

    test('a document matching many chunks arrives as one result', () async {
      await open('doc_retrieval_collapse_test.db');
      await addFile('f1', 'report.pdf');
      await addFile('f2', 'other.pdf');
      for (var i = 0; i < 6; i++) {
        await addChunk('f1', i, 'budget discussion part $i', page: i + 1);
      }
      await addChunk('f2', 0, 'budget summary', page: 1);

      final results = await Bm25Retriever(db).search(parse('budget'));

      expect(results.results.length, 2,
          reason: 'six matching chunks of f1 must not take six rank slots');
      expect(results.results.map((r) => r.id).toSet(), {'f1', 'f2'});
    });

    test('counts a multi-chunk document once in the total', () async {
      await open('doc_retrieval_total_test.db');
      await addFile('f1', 'report.pdf');
      for (var i = 0; i < 4; i++) {
        await addChunk('f1', i, 'quarterly revenue $i');
      }

      final results = await Bm25Retriever(db).search(parse('quarterly'));

      expect(results.fileTotal, 1,
          reason: 'a total larger than the page can reach is the visible bug');
    });

    test('still finds a document by its filename alone', () async {
      await open('doc_retrieval_name_test.db');
      await addFile('f1', 'taxreturn.pdf');
      await addChunk('f1', 0, 'unrelated body text');

      final results = await Bm25Retriever(db).search(parse('taxreturn'));

      expect(results.results.map((r) => r.id), ['f1'],
          reason: 'adding a second index must not lose the first');
    });

    test('a file matching in both indexes is not listed twice', () async {
      await open('doc_retrieval_both_test.db');
      await addFile('f1', 'budget.pdf');
      await addChunk('f1', 0, 'budget for the year');

      final results = await Bm25Retriever(db).search(parse('budget'));

      expect(results.results.length, 1);
      expect(results.fileTotal, 1);
    });

    test('reports a chunk-only match as overlap, not as a new result',
        () async {
      await open('doc_retrieval_overlap_test.db');
      await addFile('f1', 'notes.pdf');
      await addChunk('f1', 0, 'minutes of the planning meeting');

      // matchingIds decides whether a vector hit is an agreement with BM25 or
      // a semantic addition. Blind to chunk text it would call this an
      // addition and inflate the reported total.
      final overlap = await Bm25Retriever(db).matchingIds(
        parse('planning'),
        SearchResultType.file,
        ['f1'],
      );

      expect(overlap, {'f1'});
    });
  });

  group('footnote provenance', () {
    test('cites the best-scoring passage, not an arbitrary one', () async {
      await open('doc_footnote_best_test.db');
      await addFile('f1', 'report.pdf');
      // Only chunk 2 mentions the query term, so it must be the one cited —
      // this is the SQLite bare-column-with-MIN() behaviour the query relies
      // on, pinned so an innocuous rewrite cannot silently break it.
      await addChunk('f1', 0, 'introduction and preamble', page: 1);
      await addChunk('f1', 1, 'background material', page: 7);
      await addChunk('f1', 2, 'the depreciation schedule', page: 13);

      final results = await Bm25Retriever(db).search(parse('depreciation'));

      expect(results.results.single.citation?.chunkIndex, 2);
      expect(results.results.single.citation?.page, 13);
      expect(results.results.single.citation?.label, 'page 13');
    });

    test('falls back to the heading path when a format has no pages', () async {
      await open('doc_footnote_heading_test.db');
      await addFile('f1', 'policy.doc');
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, page, heading_path, '
        'text, model_version) VALUES (?, ?, NULL, ?, ?, ?)',
        ['f1', 0, 'Policy > Publishing', 'external publishing rules', 'm'],
      );

      final results = await Bm25Retriever(db).search(parse('publishing'));

      expect(results.results.single.citation?.page, isNull);
      expect(results.results.single.citation?.label, 'Policy > Publishing');
    });

    test('a filename match cites nothing', () async {
      await open('doc_footnote_namematch_test.db');
      await addFile('f1', 'depreciation.pdf');
      await addChunk('f1', 0, 'unrelated contents', page: 4);

      final results = await Bm25Retriever(db).search(parse('depreciation'));

      expect(results.results.single.citation, isNull,
          reason: 'matching on the name is the absence of a passage, not '
              'passage 0 — a footnote here would cite text nobody searched');
    });

    test('carries the parent email of an attachment', () async {
      await open('doc_footnote_parent_test.db');
      await db.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject) '
        "VALUES ('m1', 'col-1', 0, 'a\@b.com', 'me\@x.com', 'Q3 numbers')",
      );
      await addFile('f1', 'attachment.pdf');
      await db.rawDb.execute("UPDATE files SET email_id='m1' WHERE id='f1'");
      await addChunk('f1', 0, 'quarterly figures', page: 2);

      final results = await Bm25Retriever(db).search(parse('quarterly'));

      expect(results.results.single.parentEmailId, 'm1');
    });
  });

  group('VectorHit chunk provenance', () {
    test('a photo hit carries no chunk sequence', () {
      // emb_sequence is NOT NULL DEFAULT 0, so every image row reads 0.
      // Treating that as "chunk 0" would put a footnote citing a passage that
      // does not exist on every photo in the archive.
      const hit = VectorHit(
        type: SearchResultType.file,
        id: 'f1',
        similarity: 0.9,
      );
      expect(hit.chunkSequence, isNull);
    });

    test('a chunk hit remembers which chunk won', () {
      const hit = VectorHit(
        type: SearchResultType.file,
        id: 'f1',
        similarity: 0.9,
        chunkSequence: 7,
      );
      expect(hit.chunkSequence, 7);
      expect(hit.toString(), contains('chunk 7'));
    });
  });

  group('Mode B over-fetch reporting', () {
    test('is silent while the fetch covers the corpus', () {
      expect(
        VectorRetriever.overFetchMessage(SearchResultType.file, 16000, 10600),
        isNull,
      );
    });

    test('warns once the fetch is a minority of the corpus', () {
      // The condition that makes the multiplier matter: below this, one
      // document's chunks can crowd others out of the top-N before dedup.
      final message = VectorRetriever.overFetchMessage(
        SearchResultType.file,
        16000,
        90000,
      );
      expect(message, isNotNull);
      expect(message, contains('Raise the over-fetch multiplier'));
    });

    test('says nothing about an empty corpus', () {
      expect(
        VectorRetriever.overFetchMessage(SearchResultType.file, 16000, 0),
        isNull,
        reason: 'an unindexed archive is not an under-fetch',
      );
    });
  });
}
