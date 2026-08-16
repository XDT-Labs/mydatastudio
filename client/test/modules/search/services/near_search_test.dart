import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/search_query.dart';
import 'package:mydatastudio/modules/search/services/near_resolver.dart';
import 'package:mydatastudio/modules/search/services/place_repository.dart';
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

/// A stand-in for the bundled asset: the same trimmed-TSV-then-gzip shape,
/// small enough to assert against exactly.
Uint8List _gazetteer(List<String> rows) {
  return Uint8List.fromList(io.gzip.encode(utf8.encode(rows.join('\n'))));
}

const _banff = '5892532\tBanff\tBanff\t51.17622\t-115.56982\tCA\t01\t8305';
const _zurich = '2657896\tZürich\tZurich\t47.36667\t8.55\tCH\tZH\t341730';
// Two namesakes, so tie-breaking has something to break.
const _springfieldMo =
    '4409896\tSpringfield\tSpringfield\t37.21533\t-93.29824\tUS\tMO\t169176';
const _springfieldIl =
    '4250542\tSpringfield\tSpringfield\t39.80172\t-89.64371\tUS\tIL\t116565';

Future<void> _addPhoto(
  AppDatabase db, {
  required String id,
  required String name,
  double? latitude,
  double? longitude,
  String description = '',
}) {
  return db.rawDb.execute(
    'INSERT INTO files (id, name, path, parent, date_created, collection_id, '
    'content_type, size, is_deleted, is_inline, latitude, longitude, '
    'description) '
    'VALUES (?, ?, ?, ?, 1000, ?, ?, 1, 0, 0, ?, ?, ?)',
    [
      id,
      name,
      '/photos/$name',
      '/photos',
      'c1',
      'image/jpeg',
      latitude,
      longitude,
      description,
    ],
  );
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

  group('gazetteer import', () {
    test('loads the trimmed TSV and is idempotent', () async {
      final db = await _freshDb('places_import_test.db');
      final repo = PlaceRepository(db);

      final written = await repo.importIfEmpty(
        loadAsset: () async => _gazetteer([_banff, _zurich]),
      );
      expect(written, 2);
      expect(await repo.count(), 2);

      // Called on every launch, so a second run must not re-pay the import or
      // duplicate a single row.
      final again = await repo.importIfEmpty(
        loadAsset: () async => _gazetteer([_banff, _zurich]),
      );
      expect(again, 0);
      expect(await repo.count(), 2);

      await db.close();
    });

    test('skips malformed lines instead of failing the whole import', () async {
      // The asset ships with the app, so a bad line means a bad build — but
      // losing `near:` entirely over one row is a far worse outcome than
      // losing one town.
      final db = await _freshDb('places_malformed_test.db');
      final repo = PlaceRepository(db);

      final written = await repo.importIfEmpty(
        loadAsset:
            () async => _gazetteer([
              _banff,
              'not\ta\tvalid\trow',
              '9\tNowhere\tNowhere\tnotanumber\t0\tXX\t\t1',
              '',
              _zurich,
            ]),
      );

      expect(written, 2);
      await db.close();
    });

    test(
      'a missing asset disables near: rather than failing the open',
      () async {
        final db = await _freshDb('places_missing_asset_test.db');
        final repo = PlaceRepository(db);

        final written = await repo.importIfEmpty(
          loadAsset: () async => throw Exception('asset not in bundle'),
        );

        expect(written, 0);
        expect(await repo.count(), 0);
        await db.close();
      },
    );
  });

  group('place resolution', () {
    test('matches either spelling of an accented name', () async {
      final db = await _freshDb('places_resolve_test.db');
      final repo = PlaceRepository(db);
      await repo.importIfEmpty(loadAsset: () async => _gazetteer([_zurich]));

      // "Zurich" is what an English keyboard types; "Zürich" is what the place
      // is called. Both have to reach the same point.
      expect((await repo.resolve('Zurich'))?.id, 2657896);
      expect((await repo.resolve('zürich'))?.id, 2657896);
      expect((await repo.resolve('  Zurich  '))?.id, 2657896);

      await db.close();
    });

    test('picks the most populous of several namesakes', () async {
      final db = await _freshDb('places_namesake_test.db');
      final repo = PlaceRepository(db);
      await repo.importIfEmpty(
        loadAsset: () async => _gazetteer([_springfieldIl, _springfieldMo]),
      );

      final place = await repo.resolve('Springfield');
      expect(place?.id, 4409896, reason: 'Missouri is the larger Springfield');
      expect(place?.label, 'Springfield, US');

      await db.close();
    });

    test('does not prefix-match', () async {
      // "san" resolving to whichever large city sorted first would constrain
      // the entire query to a radius around a place the user never named —
      // strictly worse than not matching, which falls through to free text.
      final db = await _freshDb('places_prefix_test.db');
      final repo = PlaceRepository(db);
      await repo.importIfEmpty(loadAsset: () async => _gazetteer([_banff]));

      expect(await repo.resolve('Ban'), isNull);
      expect(await repo.resolve(''), isNull);

      await db.close();
    });
  });

  group('NearResolver', () {
    test('attaches coordinates for a name the gazetteer knows', () async {
      final db = await _freshDb('near_resolve_place_test.db');
      await PlaceRepository(
        db,
      ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));

      final resolved = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:banff landscape'));

      final near = resolved.filtersFor(FilterField.near).single;
      expect(near.hasCoordinates, isTrue);
      expect(near.latitude, closeTo(51.17622, 1e-6));
      expect(near.placeLabel, 'Banff, CA');
      expect(resolved.freeText, 'landscape');

      await db.close();
    });

    test('keeps a landmark-only term as a filter', () async {
      final db = await _freshDb('near_resolve_landmark_test.db');
      await _addPhoto(db, id: 'f1', name: 'rome.jpg');
      await db.rawDb.execute(
        'INSERT INTO file_landmarks (file_id, landmark) VALUES (?, ?)',
        ['f1', 'Colosseum'],
      );

      final resolved = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:colosseum'));

      final near = resolved.filtersFor(FilterField.near).single;
      expect(near.hasCoordinates, isFalse);
      expect(resolved.freeText, isEmpty);

      await db.close();
    });

    test('demotes an unresolvable place to free text', () async {
      // The behaviour that keeps `near:` from being a trap. A village too small
      // for the gazetteer is still a word the user typed, and BM25 will find it
      // in a filename or an AI description. Left as a filter it would constrain
      // the query to zero rows and report "no results" for a query that has
      // perfectly good answers.
      final db = await _freshDb('near_resolve_demote_test.db');
      await PlaceRepository(
        db,
      ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));

      final resolved = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:tuktoyaktuk sunset'));

      expect(resolved.filtersFor(FilterField.near), isEmpty);
      expect(resolved.freeText, 'sunset tuktoyaktuk');

      await db.close();
    });
  });

  group('near: radius search', () {
    test('returns photos inside the radius and excludes those outside', () async {
      // Also the proof that SQLITE_ENABLE_MATH_FUNCTIONS is genuinely compiled
      // in: without it `acos`/`radians` are not functions and this query throws
      // rather than returning the wrong rows.
      final db = await _freshDb('near_radius_test.db');
      await PlaceRepository(
        db,
      ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));

      // In town.
      await _addPhoto(
        db,
        id: 'in',
        name: 'bow-falls.jpg',
        latitude: 51.1784,
        longitude: -115.5708,
      );
      // Lake Louise, ~55 km away — outside the 25 km default, inside 60.
      await _addPhoto(
        db,
        id: 'near',
        name: 'lake-louise.jpg',
        latitude: 51.4254,
        longitude: -116.1773,
      );
      // Calgary, ~104 km away.
      await _addPhoto(
        db,
        id: 'far',
        name: 'calgary.jpg',
        latitude: 51.0501,
        longitude: -114.0853,
      );
      // No GPS at all — 90% of a real library.
      await _addPhoto(db, id: 'none', name: 'scan.jpg');

      final query = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:banff'));
      final results = await Bm25Retriever(db).search(query);
      expect(results.results.map((r) => r.id), ['in']);

      final wider = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:banff:60'));
      final widerResults = await Bm25Retriever(db).search(wider);
      expect(widerResults.results.map((r) => r.id).toSet(), {'in', 'near'});

      await db.close();
    });

    test(
      'a photo at the exact centre is not dropped by acos overflow',
      () async {
        // The min(1.0, ...) guard. Floating point pushes the cosine sum a hair
        // above 1.0 at zero distance, acos of which is NaN, and NaN <= 25 is
        // false — so the best possible match is the one that disappears.
        final db = await _freshDb('near_exact_centre_test.db');
        await PlaceRepository(
          db,
        ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));
        await _addPhoto(
          db,
          id: 'centre',
          name: 'town-centre.jpg',
          latitude: 51.17622,
          longitude: -115.56982,
        );

        final query = await NearResolver(
          db,
        ).resolve(QueryParser.parse('near:banff'));
        final results = await Bm25Retriever(db).search(query);

        expect(results.results.map((r) => r.id), ['centre']);
        await db.close();
      },
    );

    test('unions the radius with landmarks of the same name', () async {
      // They answer different questions about one word: where the shutter
      // fired, and what the vision model recognised. On a real archive only
      // ~10% of images carry GPS, so a landmark hit is often the only hit.
      final db = await _freshDb('near_union_test.db');
      await PlaceRepository(
        db,
      ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));
      await _addPhoto(
        db,
        id: 'gps',
        name: 'gps.jpg',
        latitude: 51.1784,
        longitude: -115.5708,
      );
      await _addPhoto(db, id: 'tagged', name: 'no-exif.jpg');
      await db.rawDb.execute(
        'INSERT INTO file_landmarks (file_id, landmark) VALUES (?, ?)',
        ['tagged', 'Banff'],
      );

      final query = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:banff'));
      final results = await Bm25Retriever(db).search(query);

      expect(results.results.map((r) => r.id).toSet(), {'gps', 'tagged'});
      await db.close();
    });

    test('combines with a date filter as an AND, not a rank', () async {
      final db = await _freshDb('near_with_date_test.db');
      await PlaceRepository(
        db,
      ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));
      await db.rawDb.execute(
        'INSERT INTO files (id, name, path, parent, date_created, '
        'collection_id, content_type, size, is_deleted, is_inline, latitude, '
        'longitude, description) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, ?)',
        [
          'old',
          'old.jpg',
          '/p/old.jpg',
          '/p',
          DateTime.utc(2019, 6, 1).millisecondsSinceEpoch,
          'c1',
          'image/jpeg',
          51.1784,
          -115.5708,
          '',
        ],
      );
      await db.rawDb.execute(
        'INSERT INTO files (id, name, path, parent, date_created, '
        'collection_id, content_type, size, is_deleted, is_inline, latitude, '
        'longitude, description) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, 0, ?, ?, ?)',
        [
          'new',
          'new.jpg',
          '/p/new.jpg',
          '/p',
          DateTime.utc(2026, 6, 1).millisecondsSinceEpoch,
          'c1',
          'image/jpeg',
          51.1784,
          -115.5708,
          '',
        ],
      );

      final query = await NearResolver(
        db,
      ).resolve(QueryParser.parse('near:banff after:2026'));
      final results = await Bm25Retriever(db).search(query);

      expect(results.results.map((r) => r.id), ['new']);
      await db.close();
    });

    test(
      'mail is excluded from a near: query rather than ranked below it',
      () async {
        final db = await _freshDb('near_excludes_mail_test.db');
        await PlaceRepository(
          db,
        ).importIfEmpty(loadAsset: () async => _gazetteer([_banff]));
        await db.rawDb.execute(
          'INSERT INTO emails (id, collection_id, date, "from", "to", subject, '
          'plain_body, has_attachments, is_deleted) '
          'VALUES (?, ?, 1000, ?, ?, ?, ?, 0, 0)',
          [
            'e1',
            'c1',
            'a@x.com',
            'me@x.com',
            'Banff trip',
            'banff banff banff',
          ],
        );

        final query = await NearResolver(
          db,
        ).resolve(QueryParser.parse('near:banff'));
        final results = await Bm25Retriever(db).search(query);

        expect(results.emailTotal, 0);
        await db.close();
      },
    );
  });
}
