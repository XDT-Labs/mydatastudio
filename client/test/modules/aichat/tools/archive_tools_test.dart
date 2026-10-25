import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/aichat/services/tools/tool_registry.dart';
import 'package:mydatastudio/modules/email/services/tools/email_tools.dart';
import 'package:mydatastudio/modules/search/services/tools/search_tools.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The five archive tools against a real (seeded) database, called the way the
/// agent loop calls them: through the registry, with JSON the model wrote.

final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

int _ms(String isoDate) => DateTime.parse(isoDate).millisecondsSinceEpoch;

Future<void> _addEmail(
  AppDatabase db, {
  required String id,
  required String from,
  required String subject,
  required String date,
  String body = '',
  String? threadId,
  String collectionId = 'mail',
}) {
  return db.rawDb.execute(
    'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
    'snippet, plain_body, body_text, thread_id, has_attachments, is_deleted) '
    "VALUES (?, ?, ?, ?, 'me@example.com', ?, ?, ?, ?, ?, 0, 0)",
    [id, collectionId, _ms(date), from, subject, body, body, body, threadId],
  );
}

Future<void> _addFile(
  AppDatabase db, {
  required String id,
  required String name,
  required String date,
  String description = '',
}) {
  return db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    "content_type, size, is_deleted, is_inline, is_favorite, description) "
    "VALUES (?, ?, ?, '/docs', ?, 'drive', 'application/pdf', 1, 0, 0, 0, ?)",
    [id, name, '/docs/$name', _ms(date), description],
  );
}

Map<String, Object?> _json(String s) => jsonDecode(s) as Map<String, Object?>;

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
  late ToolRegistry registry;

  Future<Map<String, Object?>> call(String name, Map<String, Object?> args) async {
    final result = await registry.call(name, jsonEncode(args));
    return _json(result.toJson());
  }

  setUp(() async {
    db = await _freshDb('tools_${DateTime.now().microsecondsSinceEpoch}.db');
    await db.rawDb.execute(
      'INSERT INTO collections (id, name, path, type, scanner, scan_status) VALUES '
      "('mail', 'Gmail', '/', 'email', 'gmail', 'idle'), "
      "('drive', 'Google Drive', '/', 'files', 'gdrive', 'idle')",
    );
    await _addEmail(db, id: 'e1', from: 'Sarah Lee <sarah@example.com>',
        subject: 'Lease renewal', date: '2024-04-02',
        body: 'Renewal is due May 1.', threadId: 't1');
    await _addEmail(db, id: 'e2', from: 'Bob <bob@example.com>',
        subject: 'Lease question', date: '2024-05-10', body: 'Is parking included?');
    await _addEmail(db, id: 'e3', from: 'me@example.com',
        subject: 'Re: Lease renewal', date: '2024-04-03',
        body: 'Thanks, signing today.', threadId: 't1');
    await _addEmail(db, id: 'e4', from: 'Sarah Lee <sarah@example.com>',
        subject: 'Lease renewal (old)', date: '2023-01-15', body: 'Last year.');
    await _addFile(db, id: 'f1', name: 'W-2 2023.pdf', date: '2024-02-01',
        description: 'Wage and tax statement for 2023');
    await _addFile(db, id: 'f2', name: 'kitchen-quote.pdf', date: '2025-05-19');
    registry = ToolRegistry([
      SearchToolProvider(db, (_) async => null),
      EmailToolProvider(db),
    ]);
  });

  tearDown(() async => db.close());

  group('search', () {
    test('from: is a hard filter, not a hint', () async {
      // Bob's email also mentions the lease. Recorded in Phase 0: the model
      // passes the sender as its own argument, and it must exclude Bob.
      final out = await call('search', {'query': 'lease', 'from': 'sarah'});
      final ids = (out['results'] as List).map((r) => (r as Map)['id']).toSet();
      expect(ids, {'email:e1', 'email:e4'});
    });

    test('after: narrows by date', () async {
      final out = await call('search', {
        'query': 'lease', 'from': 'sarah', 'after': '2024-03-01',
      });
      final ids = (out['results'] as List).map((r) => (r as Map)['id']).toList();
      expect(ids, ['email:e1']);
    });

    test('sources limits the archive searched', () async {
      final out = await call('search', {'query': 'tax statement', 'sources': ['file']});
      final results = out['results'] as List;
      expect(results, isNotEmpty);
      expect(results.every((r) => (r as Map)['type'] == 'file'), isTrue);
    });

    test('"*" means filters only, not a literal asterisk', () async {
      // Recorded in Phase 0: "everything billing@… sent me" came back as
      // query "*".
      final out = await call('search', {'query': '*', 'from': 'bob'});
      final ids = (out['results'] as List).map((r) => (r as Map)['id']).toList();
      expect(ids, ['email:e2']);
    });

    test('results are compact, dated and counted', () async {
      final out = await call('search', {'query': 'lease', 'limit': 1});
      final results = out['results'] as List;
      expect(results, hasLength(1));
      final hit = results.single as Map;
      expect(hit.keys, containsAll(['id', 'type', 'title', 'date']));
      expect(hit['date'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
      // Lets the model say "1 of 4" instead of claiming it saw everything.
      expect(out['total'], 4);
      expect(out['shown'], 1);
    });

    test('a quote in an argument cannot break out of the field', () async {
      final out = await call('search', {'query': 'lease', 'from': 'sarah" type:file'});
      expect(out.containsKey('error'), isFalse);
      expect(
        (out['results'] as List).every((r) => (r as Map)['type'] == 'email'),
        isTrue,
      );
    });
  });

  group('get_item', () {
    test('returns an email with its text', () async {
      final out = await call('get_item', {'id': 'email:e1'});
      expect(out['subject'], 'Lease renewal');
      expect(out['from'], contains('sarah@example.com'));
      expect(out['text'], contains('Renewal is due May 1.'));
    });

    test('returns a file with its description and extracted text', () async {
      await db.rawDb.execute(
        'INSERT INTO file_chunks (file_id, chunk_index, text) VALUES '
        "('f2', 0, 'Total estimate \$38,400'), ('f2', 1, 'Cabinets and counters')",
      );
      final out = await call('get_item', {'id': 'file:f2'});
      expect(out['name'], 'kitchen-quote.pdf');
      expect(out['text'], 'Total estimate \$38,400\nCabinets and counters');
    });

    test('long text is cut to the budget and says so', () async {
      await _addEmail(db, id: 'big', from: 'x@example.com', subject: 'Big',
          date: '2024-01-01', body: 'word ' * 5000);
      final out = await call('get_item', {'id': 'email:big'});
      expect((out['text'] as String).length, lessThanOrEqualTo(ToolBudgets.itemTextChars));
      expect(out['truncated'], isTrue);
    });

    test('an unknown id is an error the model can read', () async {
      final out = await call('get_item', {'id': 'email:nope'});
      expect(out['error'], contains('email:nope'));
    });
  });

  group('get_email_thread', () {
    test('returns the conversation oldest first', () async {
      final out = await call('get_email_thread', {'id': 'email:e3'});
      final ids = (out['messages'] as List).map((m) => (m as Map)['id']).toList();
      expect(ids, ['email:e1', 'email:e3']);
    });

    test('an email with no thread is a thread of one', () async {
      final out = await call('get_email_thread', {'id': 'email:e2'});
      expect((out['messages'] as List), hasLength(1));
    });
  });

  group('list_items', () {
    test('lists emails in a date range, newest first by default', () async {
      final out = await call('list_items', {
        'source': 'email', 'after': '2024-04-01', 'before': '2024-06-01',
      });
      final ids = (out['items'] as List).map((m) => (m as Map)['id']).toList();
      expect(ids, ['email:e2', 'email:e3', 'email:e1']);
      expect(out['total'], 3);
    });

    test('oldest sorts ascending', () async {
      final out = await call('list_items', {'source': 'file', 'sort': 'oldest'});
      final ids = (out['items'] as List).map((m) => (m as Map)['id']).toList();
      expect(ids, ['file:f1', 'file:f2']);
    });
  });

  group('list_collections', () {
    test('names each archive with its item count', () async {
      final out = await call('list_collections', {});
      final byName = {
        for (final c in out['collections'] as List)
          (c as Map)['name']: c['items'],
      };
      expect(byName, {'Gmail': 4, 'Google Drive': 2});
    });
  });

  test('all five tools are registered under the names the model was evaluated on', () {
    // The Phase 0 eval measured these exact names; renaming one invalidates it.
    expect(registry.tools.map((t) => t.name).toSet(), {
      'search', 'get_item', 'get_email_thread', 'list_items', 'list_collections',
    });
  });
}
