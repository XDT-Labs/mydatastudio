import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_result.dart';
import 'package:mydatastudio/modules/search/services/archive_search.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// [ArchiveSearch] is the search pipeline without the search page's state.
///
/// It exists for the LLM tools (docs/plans/llm-tools.md, Phase 2): a tool that
/// went through [SearchService] would reset the user's search page — its
/// cursors, its loading flag, and the results stream it is rendering.

const _dim = 2048;
final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

List<double> _vector(int axis) {
  final v = List<double>.filled(_dim, 0.0);
  v[axis] = 1.0;
  return v;
}

Future<void> _addFile(
  AppDatabase db, {
  required String id,
  required String name,
  String description = '',
  List<double>? vector,
}) async {
  await db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    "content_type, size, is_deleted, is_inline, is_favorite, description) "
    "VALUES (?, ?, ?, '/p', ?, 'c1', 'application/pdf', 1, 0, 0, 0, ?)",
    [
      id,
      name,
      '/p/$name',
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
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
  });

  late AppDatabase db;

  setUp(() async {
    db = await _freshDb('archive_search_${DateTime.now().microsecondsSinceEpoch}.db');
    await db.rawDb.execute(
      'INSERT INTO collections (id, name, path, type, scanner, scan_status) '
      "VALUES ('c1', 'c1', '/', 'files', 'local', 'idle')",
    );
  });

  tearDown(() async => db.close());

  test('top() caps the list but reports the real total', () async {
    for (var i = 0; i < 5; i++) {
      await _addFile(db, id: 'f$i', name: 'lease-$i.pdf');
    }
    final retrieval = await ArchiveSearch(
      db,
      (_) async => null, // no semantic pass
    ).retrieve('lease');

    final top = retrieval.top(2);
    expect(top.results, hasLength(2));
    // The model must be able to say "2 of 5", not imply it saw everything.
    expect(top.fileTotal, 5);
  });

  test('a semantic-only hit is returned and counted in the total', () async {
    await _addFile(db, id: 'kw', name: 'lease.pdf', vector: _vector(1));
    // No keyword in common with the query; only the vector pass finds it.
    await _addFile(
      db,
      id: 'sem',
      name: 'scan_0042.pdf',
      vector: _vector(0),
    );
    final retrieval = await ArchiveSearch(
      db,
      (_) async => _vector(0),
    ).retrieve('lease');

    final ids = retrieval.top(10).results.map((r) => r.id).toSet();
    expect(ids, containsAll(['kw', 'sem']));
    expect(retrieval.top(10).fileTotal, 2);
  });

  test('an empty query is blank, not an error', () async {
    final retrieval = await ArchiveSearch(db, (_) async => null).retrieve('');
    expect(retrieval.isBlank, isTrue);
    expect(retrieval.top(5).results, isEmpty);
  });

  test('a source restriction excludes the other archive', () async {
    await _addFile(db, id: 'f1', name: 'lease.pdf');
    final retrieval = await ArchiveSearch(
      db,
      (_) async => null,
    ).retrieve('lease', onlySource: SearchResultType.email);
    expect(retrieval.top(5).results, isEmpty);
  });

  test('running it leaves the search page untouched', () async {
    await _addFile(db, id: 'f1', name: 'lease.pdf');
    final page = SearchService()..embedder = (_) async => null;
    await page.invoke(SearchCommand('lease', db));
    final before = page.sink.value;

    final emitted = <SearchResults>[];
    final sub = page.sink.skip(1).listen(emitted.add);
    await ArchiveSearch(db, (_) async => null).retrieve('nothing matches this');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(emitted, isEmpty);
    expect(page.sink.value, same(before));
    expect(page.lastQuery?.raw, 'lease');
  });
}
