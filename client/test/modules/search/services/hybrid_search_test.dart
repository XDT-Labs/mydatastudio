import 'dart:io' as io;
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/result_ranking.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

Future<void> _addCollection(AppDatabase db, String id, String scanner) {
  return db.rawDb.execute(
    'INSERT OR REPLACE INTO collections (id, name, path, type, scanner, '
    "scan_status) VALUES (?, ?, '/', 'files', ?, 'idle')",
    [id, id, scanner],
  );
}

Future<void> _addFile(
  AppDatabase db, {
  required String id,
  String name = 'IMG_0001.jpg',
  String description = '',
  String collectionId = 'c1',
  int isFavorite = 0,
  int? dateCreated,
  List<double>? vector,
}) async {
  await db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    "content_type, size, is_deleted, is_inline, is_favorite, description) "
    "VALUES (?, ?, ?, '/p', ?, ?, 'image/jpeg', 1, 0, 0, ?, ?)",
    [
      id,
      name,
      '/p/$name',
      dateCreated ?? _recent,
      collectionId,
      isFavorite,
      description,
    ],
  );
  if (vector != null) {
    await db.rawDb.execute(
      'INSERT INTO files_embeddings (file_id, type, qwen3_vl_embedding) '
      "VALUES (?, 'file', vector_as_f32(?))",
      [id, '[${vector.join(',')}]'],
    );
  }
}

/// A service wired to a fixed embedding, standing in for the AI subprocess.
SearchService _service(List<double>? queryVector) {
  return SearchService()..embedder = (_) async => queryVector;
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

  test('a semantic match with none of the query words still surfaces', () async {
    // The reason the vector pass exists at all. A photo whose file name is
    // IMG_0001.jpg and whose description never says "graduation" is invisible
    // to keyword search, and it is exactly the thing a personal archive is
    // asked for years later.
    final db = await _freshDb('hybrid_semantic_only_test.db');
    await _addCollection(db, 'c1', 'file.local');
    await _addFile(db, id: 'lexical', name: 'graduation.jpg');
    await _addFile(db, id: 'semantic', vector: _vector(0));

    final results = await _service(
      _vector(0),
    ).invoke(SearchCommand('graduation', db));

    expect(results.results.map((r) => r.id), containsAll(['lexical', 'semantic']));
    await db.close();
  });

  test('a hard filter still excludes a perfect semantic match', () async {
    // The invariant the whole design rests on, checked at the level where
    // fusion could plausibly have undone it: a filter must survive being mixed
    // with a second retriever's opinion.
    final db = await _freshDb('hybrid_filter_test.db');
    await _addCollection(db, 'c1', 'file.local');
    await _addFile(
      db,
      id: 'old',
      dateCreated: DateTime.utc(2019, 5, 1).millisecondsSinceEpoch,
      vector: _vector(0),
    );
    await _addFile(
      db,
      id: 'new',
      dateCreated: DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
      vector: _vector(0, lean: 0.3),
    );

    final results = await _service(
      _vector(0),
    ).invoke(SearchCommand('after:2026 sunset', db));

    expect(results.results.map((r) => r.id), ['new']);
    await db.close();
  });

  test('a favourited photo outranks a marginally better match', () async {
    // What the tier boost is for. RRF scores sit in a narrow band, so the
    // multiplier is meant to be decisive here — favouriting is the only
    // explicit signal a user ever gives about their own archive.
    final db = await _freshDb('hybrid_tier_test.db');
    await _addCollection(db, 'c1', 'file.local');
    await _addFile(db, id: 'plain', vector: _vector(0));
    await _addFile(db, id: 'favorite', isFavorite: 1, vector: _vector(0, lean: 0.95));

    final results = await _service(
      _vector(0),
    ).invoke(SearchCommand('sunset', db));

    expect(results.results.first.id, 'favorite');
    expect(results.results.first.tier, SourceTier.curatedByUser);
    await db.close();
  });

  test('an attachment from mail ranks below a file kept on disk', () async {
    final db = await _freshDb('hybrid_attachment_tier_test.db');
    await _addCollection(db, 'c1', 'file.local');
    await _addCollection(db, 'c2', 'email.gmail');
    await _addFile(db, id: 'kept', collectionId: 'c1', vector: _vector(0, lean: 0.9));
    await _addFile(db, id: 'attached', collectionId: 'c2', vector: _vector(0));

    final results = await _service(
      _vector(0),
    ).invoke(SearchCommand('invoice', db));

    expect(results.results.map((r) => r.id), ['kept', 'attached']);
    expect(results.results.last.tier, SourceTier.receivedAttachment);
    await db.close();
  });

  test('the reported total is reachable by scrolling', () async {
    // The count and the list have to agree. A semantic hit the keywords also
    // found is already inside the lexical total, so counting it again as an
    // addition would advertise results that do not exist.
    final db = await _freshDb('hybrid_total_test.db');
    await _addCollection(db, 'c1', 'file.local');
    // Found by both retrievers.
    await _addFile(db, id: 'both', name: 'sunset.jpg', vector: _vector(0));
    // Found only by keywords.
    await _addFile(db, id: 'lexical', name: 'sunset-2.jpg');
    // Found only by the vector pass.
    await _addFile(db, id: 'semantic', vector: _vector(0, lean: 0.9));

    final service = _service(_vector(0));
    final results = await service.invoke(SearchCommand('sunset', db));

    expect(results.total, 3);
    expect(results.results.length, 3);
    expect(results.hasMore, isFalse);
    await db.close();
  });

  test('paging through the fused head never repeats a result', () async {
    // The head is ranked in one pass and served from memory; the lexical tail
    // resumes afterwards from where the window ended. Getting the handover
    // wrong shows the same photo twice, which reads as a broken search.
    final db = await _freshDb('hybrid_paging_test.db');
    await _addCollection(db, 'c1', 'file.local');
    for (var i = 0; i < 25; i++) {
      await _addFile(
        db,
        id: 'f$i',
        name: 'sunset-$i.jpg',
        vector: _vector(i * 10),
      );
    }

    final service = _service(_vector(0));
    await service.invoke(SearchCommand('sunset', db, limit: 10));
    expect(service.hasMore, isTrue);

    var guard = 0;
    while (service.hasMore && ++guard < 20) {
      await service.loadMore();
    }

    final all = service.sink.value!.results;
    final seen = <String>{};
    for (final r in all) {
      expect(seen.add(r.key), isTrue, reason: '${r.id} appeared twice');
    }
    expect(all.length, 25);
    expect(service.hasMore, isFalse);
    await db.close();
  });

  test('an unavailable embedder leaves lexical search untouched', () async {
    // Degrading is fine; breaking is not. With the AI subprocess down this has
    // to behave exactly like the lexical-only search that shipped before it.
    final db = await _freshDb('hybrid_no_embedder_test.db');
    await _addCollection(db, 'c1', 'file.local');
    await _addFile(db, id: 'lexical', name: 'sunset.jpg');
    await _addFile(db, id: 'semantic', vector: _vector(0));

    final results = await _service(null).invoke(SearchCommand('sunset', db));

    expect(results.results.map((r) => r.id), ['lexical']);
    expect(results.total, 1);
    await db.close();
  });
}
