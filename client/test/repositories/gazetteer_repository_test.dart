import 'dart:io' as io;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/repositories/gazetteer_repository.dart';

/// The gazetteer is what makes the Photos location filter usable at all — a
/// user types a city name, and these rules decide whether the place they meant
/// comes back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GazetteerRepository.fold', () {
    // The stored search columns are folded by tool/build_gazetteer.py. If Dart
    // folds differently the query simply never matches, with no error to
    // explain it — so these cases pin the two implementations together.
    test('strips diacritics so an unaccented query matches', () {
      expect(GazetteerRepository.fold('Zürich'), 'zurich');
      expect(GazetteerRepository.fold('São Paulo'), 'sao paulo');
      expect(GazetteerRepository.fold('Malmö'), 'malmo');
      expect(GazetteerRepository.fold('Kraków'), 'krakow');
    });

    test('lowercases', () {
      expect(GazetteerRepository.fold('SAN FRANCISCO'), 'san francisco');
    });

    test('expands ligatures the way the asset builder does', () {
      expect(GazetteerRepository.fold('Æbeltoft'), 'aebeltoft');
      expect(GazetteerRepository.fold('Gießen'), 'giessen');
    });

    test('leaves an already-plain name alone', () {
      expect(GazetteerRepository.fold('Austin'), 'austin');
    });
  });

  group('GazetteerRepository.search', () {
    late io.Directory tempDir;
    late DatabaseManager databaseManager;
    late AppDatabase db;
    late GazetteerRepository gazetteer;

    Future<void> addPlace(
      String name,
      String region,
      String country,
      double lat,
      double lng,
      int population, {
      String? searchAlt,
    }) async {
      await db.execute(
        'INSERT INTO locations (name, region, country, latitude, longitude,'
        ' population, search_name, search_alt)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [
          name,
          region,
          country,
          lat,
          lng,
          population,
          GazetteerRepository.fold(name),
          searchAlt,
        ],
      );
    }

    setUp(() async {
      tempDir = await io.Directory.systemTemp.createTemp('mydatastudio_gaz_');

      const MethodChannel channel = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            return tempDir.path;
          });

      databaseManager = DatabaseManager.instance;
      await databaseManager.initializeDatabase();
      db = databaseManager.database!;
      gazetteer = GazetteerRepository(db);

      // Pre-seeded, so search() short-circuits its asset load — the bundle is
      // not available under `flutter test`.
      await addPlace('Austin', 'Texas', 'United States', 30.26715, -97.74306,
          974447);
      await addPlace('Austin', 'Minnesota', 'United States', 43.66663,
          -92.97464, 24563);
      await addPlace('Zürich', 'Zurich', 'Switzerland', 47.36667, 8.55, 415367,
          searchAlt: 'zuerich');
      await addPlace('Sansepolcro', 'Tuscany', 'Italy', 43.5717, 12.13959,
          16000);
      await addPlace('San Francisco', 'California', 'United States', 37.77493,
          -122.41942, 864816);
    });

    tearDown(() async {
      databaseManager.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('orders same-named places by population', () async {
      // Someone typing "austin" almost certainly means the one with a million
      // people in it, not the one in Minnesota.
      final results = await gazetteer.search('austin');

      expect(results.map((p) => p.region).toList(), ['Texas', 'Minnesota']);
    });

    test('matches a prefix, not a substring', () async {
      // "san" offering Sansepolcro above San Francisco is the behaviour that
      // makes a substring match useless as an autocomplete.
      final results = await gazetteer.search('san fran');

      expect(results.map((p) => p.name).toList(), ['San Francisco']);
    });

    test('finds an accented place from an unaccented query', () async {
      final results = await gazetteer.search('zurich');

      expect(results.single.name, 'Zürich');
    });

    test('finds a place by its transliterated spelling', () async {
      // Folding turns Zürich into "zurich"; it cannot produce GeoNames' own
      // "Zuerich", which is why search_alt exists as a second match column.
      final results = await gazetteer.search('zuerich');

      expect(results.single.name, 'Zürich');
    });

    test('treats a typed wildcard as a literal', () async {
      // Unescaped, '%' would match every place in the table and hand the user
      // an arbitrary top-20 they never asked for.
      final results = await gazetteer.search('%');

      expect(results, isEmpty);
    });

    test('an empty query returns nothing rather than everything', () async {
      expect(await gazetteer.search('   '), isEmpty);
    });

    test('label reads as city, region, country', () async {
      final results = await gazetteer.search('austin');

      expect(results.first.label, 'Austin, Texas, United States');
    });

    test('seeds the shipped asset and finds a real city in it', () async {
      // The one test that exercises the whole pipeline the feature rests on:
      // the asset built by tool/build_gazetteer.py, parsed by _seed, matched
      // by the same fold that wrote its search columns. A column order or
      // encoding drift between the two would slip past every other test here,
      // because they all insert their own rows.
      await db.execute('DELETE FROM locations');
      GazetteerRepository.resetSeedingForTest();

      final results = await GazetteerRepository(db).search('tromso');

      expect(
        results.map((p) => p.name),
        contains('Tromsø'),
        reason: 'folding in Dart must agree with the asset builder in Python',
      );

      final rows = await db.select('SELECT COUNT(*) AS c FROM locations');
      expect(rows.first['c'] as int, greaterThan(50000));
    });

    test('label drops a region that just restates the city', () async {
      // GeoNames names many regions after their principal city, and
      // "Luxembourg, Luxembourg, Luxembourg" reads like a rendering bug.
      await addPlace(
        'Luxembourg',
        'Luxembourg',
        'Luxembourg',
        49.61167,
        6.13,
        76684,
      );

      final results = await gazetteer.search('luxembourg');

      expect(results.single.label, 'Luxembourg, Luxembourg');
    });
  });
}
