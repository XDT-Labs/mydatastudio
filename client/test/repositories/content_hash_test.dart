import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/file_sources/sync_folder/online_only_checker.dart';
import 'package:mydatastudio/helpers/content_hasher.dart';
import 'package:mydatastudio/models/tables/file.dart';
import 'package:mydatastudio/modules/files/services/repositories/file_repository.dart';
import 'package:mydatastudio/repositories/database_repository.dart';
import 'package:mydatastudio/services/embedding_message_handler.dart';
import 'package:mydatastudio/app_logger.dart';
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

File _file(String id, {String? hash, String collection = 'c1'}) => File(
  id: id,
  name: '$id.jpg',
  path: '$id.jpg',
  parent: '',
  dateCreated: DateTime.fromMillisecondsSinceEpoch(1000000),
  dateLastModified: DateTime.fromMillisecondsSinceEpoch(1000000),
  collectionId: collection,
  contentType: 'image/jpeg',
  size: 10,
  isDeleted: false,
  contentHash: hash,
);

class _FakeChecker implements OnlineOnlyChecker {
  _FakeChecker(this.result);
  final bool result;
  @override
  bool isOnlineOnly(String path) => result;
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
        final f = io.File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
    }
  });

  test('File round-trips contentHash through toDbMap/fromDbMap', () {
    final f = _file('a', hash: 'abc123');
    expect(File.fromDbMap(f.toDbMap()).contentHash, 'abc123');
    expect(File.fromDbMap(_file('b').toDbMap()).contentHash, isNull);
  });

  group('contentHashStale', () {
    final t = DateTime.fromMillisecondsSinceEpoch(5000000);
    test('new file needs a hash', () {
      expect(
        contentHashStale(
          cachedSize: null,
          cachedModified: null,
          size: 1,
          modified: t,
        ),
        isTrue,
      );
    });
    test('unchanged size and mtime (sub-second drift) is not re-hashed', () {
      expect(
        contentHashStale(
          cachedSize: 1,
          cachedModified: t,
          size: 1,
          modified: t.add(const Duration(milliseconds: 400)),
        ),
        isFalse,
      );
    });
    test('size change or mtime change triggers a re-hash', () {
      expect(
        contentHashStale(
          cachedSize: 1,
          cachedModified: t,
          size: 2,
          modified: t,
        ),
        isTrue,
      );
      expect(
        contentHashStale(
          cachedSize: 1,
          cachedModified: t,
          size: 1,
          modified: t.add(const Duration(seconds: 5)),
        ),
        isTrue,
      );
    });
  });

  test('sha256OfFile matches the lowercase sha256 hex of the bytes', () async {
    final dir = await io.Directory.systemTemp.createTemp('hash_');
    final f = io.File(p.join(dir.path, 'x.bin'))..writeAsBytesSync([1, 2, 3]);
    expect(await sha256OfFile(f), sha256.convert([1, 2, 3]).toString());
    await dir.delete(recursive: true);
  });

  test('online-only files are not hashed (reading would download them)', () async {
    var hashed = 0;
    Future<String> counting(io.File _) async {
      hashed++;
      return 'h';
    }

    final f = io.File('/nonexistent/placeholder.pdf');
    expect(
      await hashUnlessOnlineOnly(f, _FakeChecker(true), hasher: counting),
      isNull,
    );
    expect(hashed, 0);
    expect(
      await hashUnlessOnlineOnly(f, _FakeChecker(false), hasher: counting),
      'h',
    );
    expect(hashed, 1);
  });

  group('database', () {
    late AppDatabase db;
    late FileDesktopRepository repo;

    setUp(() async {
      db = await _freshDb('content_hash_repo_test.db');
      repo = FileDesktopRepository(db);
      for (final c in ['c1', 'c2']) {
        await db.rawDb.execute(
          'INSERT OR REPLACE INTO collections (id, name, path, type, scanner, '
          "scan_status) VALUES ('$c', '$c', '/p', 'files', 'file.local', 'idle')",
        );
      }
    });
    tearDown(() => db.close());

    test('upsert with a null hash does not wipe an existing hash', () async {
      await repo.upsertAll([_file('a', hash: 'h1')]);
      await repo.upsertAll([_file('a')]);
      expect((await repo.getByPath(_file('a')))!.contentHash, 'h1');
      await repo.upsertAll([_file('a', hash: 'h2')]);
      expect((await repo.getByPath(_file('a')))!.contentHash, 'h2');
    });

    test('duplicatesOf finds live same-hash files across collections', () async {
      await repo.upsertAll([
        _file('a', hash: 'h1'),
        _file('b', hash: 'h1', collection: 'c2'),
        _file('c', hash: 'h2'),
        _file('d', hash: 'h1'),
        _file('e'),
      ]);
      await db.rawDb.execute("UPDATE files SET is_deleted = 1 WHERE id = 'd'");

      final dups = await repo.duplicatesOf(_file('a', hash: 'h1'));
      expect(dups.map((f) => f.id), ['b']);
      expect(await repo.duplicatesOf(_file('e')), isEmpty);

      final groups = await repo.duplicateGroups();
      expect(groups.keys, ['h1']);
      expect(groups['h1']!.map((f) => f.id), ['a', 'b']);
    });

    test('a file reuses the embedding of a byte-identical sibling', () async {
      final dbRepo = DatabaseRepository(db);
      await repo.upsertAll([
        _file('a', hash: 'h1'),
        _file('b', hash: 'h1', collection: 'c2'),
        _file('c', hash: 'h2'),
      ]);
      expect(await dbRepo.findEmbeddedDuplicate('b', 'h1'), isNull);

      await dbRepo.upsertFileEmbedding('a', List<double>.filled(2048, 0.5));
      expect(await dbRepo.findEmbeddedDuplicate('b', 'h1'), 'a');
      expect(await dbRepo.findEmbeddedDuplicate('c', 'h2'), isNull);

      // Through the relay handler, as the isolate sends it.
      await handleEmbeddingMessage(dbRepo, {
        'type': 'embedding',
        'table': 'files_embeddings',
        'id': 'b',
        'copyFrom': 'a',
      }, AppLogger(null));

      final rows = await db.rawDb.select(
        'SELECT file_id, length(qwen3_vl_embedding) AS n, model_version '
        "FROM files_embeddings WHERE type = 'file' ORDER BY file_id",
      );
      expect(rows.map((r) => r['file_id']), ['a', 'b']);
      expect(rows[1]['n'], rows[0]['n']);
      expect(rows[1]['model_version'], rows[0]['model_version']);
      expect(await dbRepo.getFilesWithMissingEmbeddings(), isNot(
        contains(predicate<File>((f) => f.id == 'b')),
      ));
    });
  });
}
