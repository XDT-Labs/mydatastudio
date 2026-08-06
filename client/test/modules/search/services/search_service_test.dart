import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/search_service.dart';
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

  test('an empty query is not a failed search', () async {
    // "No query yet" and "no results found" are different states and the UI
    // renders them differently. Collapsing them makes a freshly-opened search
    // page accuse the user of having found nothing.
    final db = await _freshDb('search_service_empty_test.db');
    final service = SearchService();

    final results = await service.invoke(SearchCommand('   ', db));

    expect(results.isEmpty, isTrue);
    expect(results.total, 0);
    await db.close();
  });

  test('publishes the parse alongside the results', () async {
    // The chips the page draws come from lastQuery rather than a second parse
    // of the text box, so what is displayed can never disagree with what was
    // actually filtered on.
    final db = await _freshDb('search_service_parse_test.db');
    final service = SearchService();

    await service.invoke(SearchCommand('from:bob@x.com invoice', db));

    expect(service.lastQuery, isNotNull);
    expect(
      service.lastQuery!.filtersFor(FilterField.from).single.value,
      'bob@x.com',
    );
    expect(service.lastQuery!.freeText, 'invoice');
    await db.close();
  });

  test('results reach the sink for stream subscribers', () async {
    final db = await _freshDb('search_service_sink_test.db');
    await db.rawDb.execute(
      'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
      'is_deleted) VALUES (?, ?, ?, ?, ?, ?, 0)',
      ['e1', 'c1', 1000, 'bob@x.com', 'me@x.com', 'quarterly report'],
    );
    final service = SearchService();

    await service.invoke(SearchCommand('quarterly', db));

    expect(service.sink.value.results.single.id, 'e1');
    await db.close();
  });

  test('a storage failure surfaces as empty rather than a hang', () async {
    // Parsing is total, so anything thrown here is storage-level. The page
    // must not be left spinning on it.
    //
    // SearchService logs that failure at error level, by design. Silenced for
    // the duration of this test only: a passing run that prints a red block
    // and a stack trace reads as a crash, and the noise buries real failures
    // in the suite output.
    final previousLevel = Logger.level;
    Logger.level = Level.off;
    addTearDown(() => Logger.level = previousLevel);

    final db = await _freshDb('search_service_failure_test.db');
    await db.close(); // querying a closed database throws

    final service = SearchService();
    final results = await service.invoke(SearchCommand('anything', db));

    expect(results.isEmpty, isTrue);
    expect(service.isLoading.value, isFalse);
  });
}
