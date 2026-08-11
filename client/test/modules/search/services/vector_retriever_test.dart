import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/query_parser.dart';
import 'package:mydatastudio/modules/search/services/retrievers/vector_retriever.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _dim = 2048;

/// A date comfortably inside every date filter these tests use. Epoch-adjacent
/// values look convenient but sit *before* `after:1970` once the parser
/// interprets a bare year in local time.
final _y2024 = DateTime.utc(2024, 6, 1).millisecondsSinceEpoch;
final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

/// A unit vector pointing mostly along axis [axis].
///
/// Distinct axes give near-orthogonal vectors, so "which is more similar" has
/// an answer the test controls rather than one that depends on float luck.
List<double> _vector(int axis, {double lean = 1.0}) {
  final v = List<double>.filled(_dim, 0.0);
  v[axis] = lean;
  v[(axis + 1) % _dim] = math.sqrt(1 - lean * lean);
  return v;
}

Future<void> _addFile(
  AppDatabase db, {
  required String id,
  String name = 'photo.jpg',
  int dateCreated = 1000,
  int isInline = 0,
  String? tag,
}) async {
  await db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    'content_type, size, is_deleted, is_inline, description) '
    "VALUES (?, ?, ?, '/p', ?, 'c1', 'image/jpeg', 1, 0, ?, '')",
    [id, name, '/p/$name', dateCreated, isInline],
  );
  if (tag != null) {
    await db.rawDb.execute(
      'INSERT INTO file_tags (file_id, tag) VALUES (?, ?)',
      [id, tag],
    );
  }
}

Future<void> _addFileVector(
  AppDatabase db,
  String fileId,
  List<double> vector, {
  String type = 'file',
}) {
  return db.rawDb.execute(
    'INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding) '
    'VALUES (?, ?, vector_as_f32(?))',
    [fileId, type, '[${vector.join(',')}]'],
  );
}

Future<void> _addEmail(
  AppDatabase db, {
  required String id,
  String from = 'bob@x.com',
  int date = 1000,
  List<double>? vector,
}) async {
  await db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    "plain_body, has_attachments, is_deleted) VALUES (?, 'c1', ?, ?, "
    "'me@x.com', 'subject', 'body', 0, 0)",
    [id, date, from],
  );
  if (vector != null) {
    await db.rawDb.execute(
      'INSERT INTO emails_embeddings (email_id, qwen3_vl_embedding) '
      'VALUES (?, vector_as_f32(?))',
      [id, '[${vector.join(',')}]'],
    );
  }
}

/// An embedder that always returns [vector], standing in for the AI subprocess.
QueryEmbedder _embedder(List<double>? vector) => (_) async => vector;

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

  group('failing open', () {
    test(
      'an unavailable embedder yields no hits rather than throwing',
      () async {
        // The AI subprocess may not be up, may not have the embedding model, or
        // may be mid-restart. Search has to keep working: degrading to lexical
        // is a worse search, a thrown exception is a broken one.
        final db = await _freshDb('vec_no_embedder_test.db');
        await _addFile(db, id: 'f1');
        await _addFileVector(db, 'f1', _vector(0));

        final hits = await VectorRetriever(
          db,
          _embedder(null),
        ).search(QueryParser.parse('sunset'));

        expect(hits, isEmpty);
        await db.close();
      },
    );

    test('an embedder that throws yields no hits', () async {
      final db = await _freshDb('vec_embedder_throws_test.db');
      await _addFile(db, id: 'f1');
      await _addFileVector(db, 'f1', _vector(0));

      final hits = await VectorRetriever(
        db,
        (_) async => throw Exception('connection refused'),
      ).search(QueryParser.parse('sunset'));

      expect(hits, isEmpty);
      await db.close();
    });

    test('a query with no free text is not embedded at all', () async {
      // `tag:nature` on its own is a browse, not a semantic question. Embedding
      // an empty string would cost a subprocess round trip per keystroke and
      // rank by the similarity of nothing to everything.
      final db = await _freshDb('vec_no_freetext_test.db');
      var called = false;
      final hits = await VectorRetriever(db, (_) async {
        called = true;
        return _vector(0);
      }).search(QueryParser.parse('tag:nature'));

      expect(called, isFalse);
      expect(hits, isEmpty);
      await db.close();
    });
  });

  group('Mode A — filters present', () {
    test('ranks the filtered candidates by cosine', () async {
      final db = await _freshDb('vec_mode_a_rank_test.db');
      await _addFile(db, id: 'near', tag: 'nature');
      await _addFile(db, id: 'mid', tag: 'nature');
      await _addFile(db, id: 'far', tag: 'nature');
      await _addFileVector(db, 'near', _vector(0));
      await _addFileVector(db, 'mid', _vector(0, lean: 0.7));
      await _addFileVector(db, 'far', _vector(500));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('tag:nature sunset'));

      // All three survive: three candidates is below
      // `minimumCandidatesForFloor`, so the similarity floor does not apply.
      // A median taken over three answers is one of the answers, and a filter
      // this narrow has already done the excluding. What the floor does on a
      // real candidate set is covered in similarity_floor_test.
      expect(hits.map((h) => h.id), ['near', 'mid', 'far']);
      expect(hits.first.similarity, closeTo(1.0, 1e-5));
      await db.close();
    });

    test('a hard filter excludes rather than ranks', () async {
      // The load-bearing invariant, restated for the vector pass. A photo that
      // is a perfect semantic match but fails the filter must be *absent*, not
      // merely lower — otherwise `tag:nature` looks broken in the way users
      // notice most.
      final db = await _freshDb('vec_mode_a_filter_test.db');
      await _addFile(db, id: 'tagged', tag: 'nature');
      await _addFile(db, id: 'untagged');
      // The untagged file is the *better* match.
      await _addFileVector(db, 'tagged', _vector(0, lean: 0.7));
      await _addFileVector(db, 'untagged', _vector(0));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('tag:nature sunset'));

      expect(hits.map((h) => h.id), ['tagged']);
      await db.close();
    });

    test('a file with image and description vectors takes one slot', () async {
      // Both vectors describe the same photo. Left undeduplicated the photo
      // occupies two result slots and crowds out a genuinely different one.
      final db = await _freshDb('vec_mode_a_dedup_test.db');
      await _addFile(db, id: 'f1', tag: 'nature');
      await _addFile(db, id: 'f2', tag: 'nature');
      await _addFileVector(db, 'f1', _vector(0, lean: 0.6));
      await _addFileVector(db, 'f1', _vector(0), type: 'description');
      await _addFileVector(db, 'f2', _vector(0, lean: 0.8));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('tag:nature sunset'));

      expect(hits.map((h) => h.id), ['f1', 'f2']);
      // The better of the two vectors is the one that counts, not the first.
      expect(hits.first.similarity, closeTo(1.0, 1e-5));
      await db.close();
    });

    test('inline message assets never surface', () async {
      final db = await _freshDb('vec_mode_a_inline_test.db');
      await _addFile(db, id: 'logo', isInline: 1, tag: 'nature');
      await _addFileVector(db, 'logo', _vector(0));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('tag:nature sunset'));

      expect(hits, isEmpty);
      await db.close();
    });

    test('mail and files are both searched and both ranked', () async {
      final db = await _freshDb('vec_mode_a_both_test.db');
      await _addFile(db, id: 'f1', dateCreated: _y2024);
      await _addFileVector(db, 'f1', _vector(0, lean: 0.6));
      await _addEmail(db, id: 'e1', date: _y2024, vector: _vector(0));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('after:2020 sunset'));

      expect(hits.map((h) => h.id), ['e1', 'f1']);
      expect(hits.first.type, SearchResultType.email);
      await db.close();
    });

    test('onlySource restricts which archive is scanned', () async {
      final db = await _freshDb('vec_mode_a_only_test.db');
      await _addFile(db, id: 'f1', dateCreated: _y2024);
      await _addFileVector(db, 'f1', _vector(0, lean: 0.6));
      await _addEmail(db, id: 'e1', date: _y2024, vector: _vector(0));

      final hits = await VectorRetriever(db, _embedder(_vector(0))).search(
        QueryParser.parse('after:2020 sunset'),
        onlySource: SearchResultType.file,
      );

      expect(hits.map((h) => h.id), ['f1']);
      await db.close();
    });
  });

  group('Mode B — no filters', () {
    test('ranks the whole corpus through vector_full_scan', () async {
      final db = await _freshDb('vec_mode_b_rank_test.db');
      await _addFile(db, id: 'near');
      await _addFile(db, id: 'far');
      await _addFileVector(db, 'near', _vector(0));
      await _addFileVector(db, 'far', _vector(500));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('sunset'));

      expect(hits.first.id, 'near');
      // Two candidates is below `minimumCandidatesForFloor`, so this asserts
      // ordering only — see similarity_floor_test for the floor itself.
      expect(hits.map((h) => h.id), contains('far'));
      await db.close();
    });

    test('still excludes deleted and inline files', () async {
      // vector_full_scan cannot be pre-filtered, so these have to be removed
      // after the scan — which is exactly why the surrounding WHERE exists and
      // why it must not be dropped as "no filters means no clause".
      final db = await _freshDb('vec_mode_b_exclusions_test.db');
      await _addFile(db, id: 'keep');
      await _addFile(db, id: 'logo', isInline: 1);
      await _addFileVector(db, 'keep', _vector(0, lean: 0.5));
      await _addFileVector(db, 'logo', _vector(0));

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('sunset'));

      expect(hits.map((h) => h.id), ['keep']);
      await db.close();
    });

    test('collapses a file that owns two vectors', () async {
      final db = await _freshDb('vec_mode_b_dedup_test.db');
      await _addFile(db, id: 'f1');
      await _addFileVector(db, 'f1', _vector(0));
      await _addFileVector(
        db,
        'f1',
        _vector(0, lean: 0.9),
        type: 'description',
      );

      final hits = await VectorRetriever(
        db,
        _embedder(_vector(0)),
      ).search(QueryParser.parse('sunset'));

      expect(hits.length, 1);
      await db.close();
    });
  });
}
