import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/email.dart';
import 'package:mydatastudio/modules/search/services/contact_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Email _email({
  required String id,
  required String from,
  List<String> to = const ['me@example.com'],
  List<String> cc = const [],
  int dateMs = 1000,
}) {
  return Email(
    id: id,
    collectionId: 'c1',
    date: DateTime.fromMillisecondsSinceEpoch(dateMs),
    from: from,
    to: to,
    cc: cc,
    subject: 'subject',
    isDeleted: false,
  );
}

/// Databases opened by [_freshDb], deleted in `tearDownAll`.
final _createdDbs = <String>[];

Future<AppDatabase> _freshDb(String dbName) async {
  final supportDir = await getApplicationSupportDirectory();
  final dbFile = io.File(p.join(supportDir.path, 'data', dbName));
  if (dbFile.existsSync()) dbFile.deleteSync();
  _createdDbs.add(dbFile.path);
  return AppDatabase.create(null, supportDir.path, dbName);
}

Future<Map<String, Object?>?> _contact(AppDatabase db, String address) async {
  final rows = await db.rawDb.select(
    'SELECT * FROM contacts WHERE address = ?',
    [address],
  );
  return rows.isEmpty ? null : rows.first;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => '.');
  });

  tearDownAll(() {
    // Each test opens a real on-disk database; without this the repo collects
    // one stray .db per test on every run.
    for (final path in _createdDbs) {
      for (final suffix in const ['', '-wal', '-shm']) {
        final file = io.File('$path$suffix');
        if (file.existsSync()) file.deleteSync();
      }
    }
    _createdDbs.clear();
  });

  group('ContactRepository.indexEmails', () {
    test('extracts the address out of an RFC 5322 from header', () async {
      // The whole reason this index exists: `emails."from"` stores
      // `Name <addr@host>`, so a `from:` filter comparing against the raw
      // column can never equality-match. If this regresses, every
      // sender-filtered search silently returns nothing.
      final db = await _freshDb('contacts_rfc5322_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(
          id: 'e1',
          from: '"coderabbitai[bot]" <notifications@github.com>',
        ),
      ]);

      final row = await _contact(db, 'notifications@github.com');
      expect(row, isNotNull);
      expect(row!['display_name'], 'coderabbitai[bot]');
      expect(row['local_part'], 'notifications');

      await db.close();
    });

    test('splits comma-joined recipient lists into separate contacts', () async {
      // `to`/`cc` are stored as `a@x.com,b@y.com`. Treating that column as one
      // value would put a whole recipient list into the autocomplete as a
      // single unselectable row.
      final db = await _freshDb('contacts_list_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(
          id: 'e1',
          from: 'sender@x.com',
          to: ['bmageau@hotmail.com', 'dave_meier@comcast.net'],
          cc: ['shelleyinfog@comcast.net'],
        ),
      ]);

      final rows = await db.rawDb.select('SELECT address FROM contacts');
      expect(rows.map((r) => r['address'] as String).toSet(), {
        'sender@x.com',
        'bmageau@hotmail.com',
        'dave_meier@comcast.net',
        'shelleyinfog@comcast.net',
      });

      await db.close();
    });

    test('treats case-variant addresses as one contact', () async {
      // Measured on real data: 401 distinct raw `from` values collapse to 400
      // when lowercased. Without normalization the same person occupies two
      // autocomplete rows with split message counts, so neither ranks
      // correctly.
      final db = await _freshDb('contacts_case_test.db');
      final repo = ContactRepository(db);

      // No recipients, so the only contacts that can exist are the two
      // spellings of the sender — which is exactly what must collapse to one.
      await repo.indexEmails([
        _email(id: 'e1', from: 'Bob Smith <Bob@X.COM>', to: const []),
        _email(id: 'e2', from: 'bob@x.com', to: const []),
      ]);

      final rows = await db.rawDb.select('SELECT * FROM contacts');
      expect(rows.length, 1);
      expect(rows.first['address'], 'bob@x.com');
      expect(rows.first['message_count'], 2);
      // The name arrived only on the first variant; the bare second appearance
      // must not blank it.
      expect(rows.first['display_name'], 'Bob Smith');

      await db.close();
    });

    test('counts volume and separates outbound from inbound', () async {
      // message_count is what orders the autocomplete — the person you have
      // exchanged 400 messages with must outrank one you have exchanged two
      // with, or a short prefix lands on an alphabetical accident.
      final db = await _freshDb('contacts_counts_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(id: 'e1', from: 'busy@x.com', to: ['me@example.com']),
        _email(id: 'e2', from: 'busy@x.com', to: ['me@example.com']),
        _email(id: 'e3', from: 'me@example.com', to: ['busy@x.com']),
      ]);

      final busy = await _contact(db, 'busy@x.com');
      expect(busy!['message_count'], 3);
      // Appeared as a recipient exactly once.
      expect(busy['sent_count'], 1);

      await db.close();
    });

    test('tracks first and last seen across a batch', () async {
      final db = await _freshDb('contacts_seen_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(id: 'e1', from: 'a@x.com', dateMs: 5000),
        _email(id: 'e2', from: 'a@x.com', dateMs: 1000),
        _email(id: 'e3', from: 'a@x.com', dateMs: 9000),
      ]);

      final row = await _contact(db, 'a@x.com');
      expect(row!['first_seen'], 1000);
      expect(row['last_seen'], 9000);

      await db.close();
    });

    test('an unparseable header does not abort the batch', () async {
      // Scanners hand over whatever the server sent. One malformed header must
      // not cost the contacts of every other message in the batch.
      final db = await _freshDb('contacts_malformed_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(id: 'e1', from: 'not-an-address', to: const []),
        _email(id: 'e2', from: 'good@x.com', to: const []),
      ]);

      expect(await _contact(db, 'good@x.com'), isNotNull);
      final all = await db.rawDb.select('SELECT COUNT(*) c FROM contacts');
      expect(all.first['c'], 1);

      await db.close();
    });
  });

  group('ContactRepository.resolveName', () {
    test('resolves a prose name to the addresses behind it', () async {
      // This is what makes `emails from mike nimer` produce the same hard
      // sender filter as `from:mike@x.com`. A language model does not know
      // Mike's address; the archive does.
      final db = await _freshDb('contacts_resolve_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([
        _email(id: 'e1', from: 'Mike Nimer <mike@xdtlabs.com>'),
        _email(id: 'e2', from: 'Someone Else <other@x.com>'),
      ]);

      final matches = await repo.resolveName('mike nimer');
      expect(matches.map((c) => c.address), ['mike@xdtlabs.com']);

      await db.close();
    });

    test(
      'returns every candidate for an ambiguous name, volume first',
      () async {
        // Two people share a name. Silently picking one returns a confidently
        // wrong result set, so all candidates come back for the caller to
        // disambiguate — ordered so the likeliest is first.
        final db = await _freshDb('contacts_ambiguous_test.db');
        final repo = ContactRepository(db);

        await repo.indexEmails([
          _email(id: 'e1', from: 'Mike Nimer <mike@work.com>'),
          _email(id: 'e2', from: 'Mike Nimer <mike@work.com>'),
          _email(id: 'e3', from: 'Mike Nimer <mike@home.com>'),
        ]);

        final matches = await repo.resolveName('mike nimer');
        expect(matches.length, 2);
        expect(matches.first.address, 'mike@work.com');
        expect(matches.first.messageCount, 2);

        await db.close();
      },
    );

    test('matches a bare address with no display name', () async {
      final db = await _freshDb('contacts_bare_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([_email(id: 'e1', from: 'mnimer@gmail.com')]);

      expect((await repo.resolveName('mnimer')).map((c) => c.address), [
        'mnimer@gmail.com',
      ]);
      await db.close();
    });

    test('an unknown name resolves to nothing rather than guessing', () async {
      // The caller falls back to ranked free-text retrieval on an empty
      // result. Returning a loose match instead would silently apply a hard
      // filter the user never asked for.
      final db = await _freshDb('contacts_unknown_test.db');
      final repo = ContactRepository(db);

      await repo.indexEmails([_email(id: 'e1', from: 'someone@x.com')]);

      expect(await repo.resolveName('russel jong'), isEmpty);
      expect(await repo.resolveName('   '), isEmpty);

      await db.close();
    });
  });

  group('ContactRepository.backfillFromEmails', () {
    test('indexes mail that predates the write-path hook', () async {
      // The hook in EmailUpsertService only sees mail arriving after it
      // exists. Without the backfill an upgraded install has no contacts at
      // all — no autocomplete, and prose name resolution silently degrades to
      // free text — until the next full sync.
      final db = await _freshDb('contacts_backfill_test.db');

      await db.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        [
          'old-1',
          'c1',
          4242,
          'Old Sender <old@x.com>',
          'me@example.com,second@y.com',
          'legacy',
        ],
      );
      await db.rawDb.execute('DELETE FROM contacts');

      final count = await ContactRepository(db).backfillFromEmails();
      expect(count, 1);

      final row = await _contact(db, 'old@x.com');
      expect(row!['display_name'], 'Old Sender');
      expect(await _contact(db, 'second@y.com'), isNotNull);

      await db.close();
    });

    test('is idempotent — rerunning does not inflate counts', () async {
      // It runs from a migration that can be re-attempted after a failure.
      // Additive counting without a reset would double every contact's
      // message_count on the second pass and scramble autocomplete ranking.
      final db = await _freshDb('contacts_backfill_idem_test.db');

      await db.rawDb.execute(
        'INSERT INTO emails (id, collection_id, date, "from", "to", subject) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        ['e1', 'c1', 1, 'a@x.com', 'me@example.com', 's'],
      );

      final repo = ContactRepository(db);
      await repo.backfillFromEmails();
      await repo.backfillFromEmails();

      final row = await _contact(db, 'a@x.com');
      expect(row!['message_count'], 1);

      await db.close();
    });

    test('pages through more emails than one page holds', () async {
      // Bodies are excluded from the backfill query precisely so a large
      // archive does not materialize hundreds of megabytes to count
      // addresses; paging is the other half of that bound.
      final db = await _freshDb('contacts_backfill_page_test.db');

      for (var i = 0; i < 7; i++) {
        await db.rawDb.execute(
          'INSERT INTO emails (id, collection_id, date, "from", "to", subject) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          ['e$i', 'c1', i, 'sender$i@x.com', 'me@example.com', 's'],
        );
      }

      final count = await ContactRepository(db).backfillFromEmails(pageSize: 2);
      expect(count, 7);

      final rows = await db.rawDb.select('SELECT COUNT(*) c FROM contacts');
      // 7 distinct senders + the shared recipient.
      expect(rows.first['c'], 8);

      await db.close();
    });
  });
}
