import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/models/tables/gazetteer_place.dart';

/// Place-name lookup over the embedded gazetteer.
///
/// The app ships the place list instead of calling a geocoding service: a
/// reverse-geocode request is a list of the exact coordinates the user has
/// photographed, which is the one thing a local-first archive must not send
/// anywhere. See `assets/gazetteer/README.md` for the data and its licence.
class GazetteerRepository {
  GazetteerRepository([this._db]);

  final AppDatabase? _db;

  AppDatabase? get _database => _db ?? DatabaseManager.instance.database;

  AppLogger logger = AppLogger(null);

  static const String assetPath = 'assets/gazetteer/cities.tsv.gz';

  /// Guards against two concurrent callers each seeding 70k rows — the drawer
  /// and a restored filter can both ask on the same frame.
  static Future<void>? _seeding;

  /// Lowercases and strips diacritics, so a typed `zurich` matches a stored
  /// `Zürich`.
  ///
  /// Mirrors `fold()` in `tool/build_gazetteer.py`, which produced the
  /// `search_name`/`search_alt` columns this is compared against — the two
  /// have to agree or a folded query matches nothing. Dart has no Unicode
  /// decomposition in the core libraries, so this covers the Latin-1 and
  /// Latin Extended-A range that the accented spellings of place names
  /// actually live in.
  static String fold(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      buffer.write(_foldedRune(rune));
    }
    return buffer.toString();
  }

  static String _foldedRune(int rune) {
    const map = {
      'àáâãäåāăą': 'a',
      'çćĉċč': 'c',
      'ďđ': 'd',
      'èéêëēĕėęě': 'e',
      'ĝğġģ': 'g',
      'ĥħ': 'h',
      'ìíîïĩīĭįı': 'i',
      'ĵ': 'j',
      'ķ': 'k',
      'ĺļľŀł': 'l',
      'ñńņňŉ': 'n',
      'òóôõöøōŏő': 'o',
      'ŕŗř': 'r',
      'śŝşš': 's',
      'ţťŧ': 't',
      'ùúûüũūŭůűų': 'u',
      'ŵ': 'w',
      'ýÿŷ': 'y',
      'źżž': 'z',
      'æ': 'ae',
      'œ': 'oe',
      'ß': 'ss',
    };
    final char = String.fromCharCode(rune);
    for (final entry in map.entries) {
      if (entry.key.contains(char)) return entry.value;
    }
    return char;
  }

  /// Populates the `locations` table from the bundled asset, once.
  ///
  /// Safe to call on every search: it returns immediately once the table has
  /// rows. Must run on the main isolate — the scanner isolates have no asset
  /// bundle.
  Future<void> ensureSeeded() => _seeding ??= _seed();

  /// Forgets that seeding has run, so a test can exercise it against a fresh
  /// database. Nothing in the app calls this — the seed is once per process.
  @visibleForTesting
  static void resetSeedingForTest() => _seeding = null;

  Future<void> _seed() async {
    final db = _database;
    if (db == null) return;

    try {
      final existing = await db.select(
        'SELECT EXISTS(SELECT 1 FROM locations LIMIT 1) AS seeded',
      );
      if (existing.isNotEmpty && (existing.first['seeded'] as int? ?? 0) == 1) {
        return;
      }

      final compressed = await rootBundle.load(assetPath);
      final bytes = io.gzip.decode(compressed.buffer.asUint8List());
      final lines = const LineSplitter().convert(utf8.decode(bytes));

      final rows = <List<Object?>>[];
      for (final line in lines) {
        if (line.isEmpty) continue;
        final f = line.split('\t');
        if (f.length < 9) continue;
        rows.add([
          f[0], // name
          f[1].isEmpty ? null : f[1], // region
          f[2], // country
          double.tryParse(f[3]) ?? 0.0,
          double.tryParse(f[4]) ?? 0.0,
          int.tryParse(f[5]) ?? 0,
          f[6], // search_name
          f[7].isEmpty ? null : f[7], // search_alt
          f[8], // search_extra
        ]);
      }

      await db.executeBatch(
        'INSERT INTO locations (name, region, country, latitude, longitude,'
        ' population, search_name, search_alt, search_extra)'
        ' VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        rows,
      );
      logger.i('GazetteerRepository: seeded ${rows.length} places');
    } catch (e, stackTrace) {
      // A failed seed leaves location search finding nothing, which is
      // recoverable; it must not take the Photos drawer down with it.
      logger.e(
        'GazetteerRepository: seeding failed: $e',
        error: e,
        stackTrace: stackTrace,
      );
      _seeding = null;
      rethrow;
    }
  }

  /// `%` and `_` are literals in a typed query, not wildcards.
  static String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Splits a typed query into a place name and the qualifiers after it.
  ///
  /// "Naperville, IL" is how people write a city, so the comma is a separator
  /// and everything past it narrows the name rather than extending it.
  static ({String name, List<String> qualifiers}) parseQuery(String query) {
    final parts = fold(query).split(',');
    final name = parts.first.trim();
    final qualifiers = <String>[];
    for (final part in parts.skip(1)) {
      qualifiers.addAll(part.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty));
    }
    return (name: name, qualifiers: qualifiers);
  }

  /// Places matching [query], most populous first.
  ///
  /// The name is matched as a prefix — it is what the `search_name` index can
  /// serve, and offering "Sansepolcro" ahead of "San Francisco" for "san" is
  /// not a useful autocomplete. Anything after a comma narrows that by region
  /// or country, spelled out or abbreviated, so both "Springfield, Illinois"
  /// and "Springfield, IL" reach the same place.
  Future<List<GazetteerPlace>> search(String query, {int limit = 20}) async {
    final db = _database;
    if (db == null) return [];

    final parsed = parseQuery(query);
    if (parsed.name.isEmpty) return [];

    try {
      await ensureSeeded();
    } catch (_) {
      return [];
    }

    final namePattern = '${_escapeLike(parsed.name)}%';
    final where = StringBuffer(
      "(search_name LIKE ? ESCAPE '\\' OR search_alt LIKE ? ESCAPE '\\')",
    );
    final args = <Object?>[namePattern, namePattern];

    for (final qualifier in parsed.qualifiers) {
      // Anchored to a token boundary so "il" reaches Illinois without also
      // reaching Brazil.
      where.write(" AND ' ' || search_extra LIKE ? ESCAPE '\\'");
      args.add('% ${_escapeLike(qualifier)}%');
    }

    args.add(limit);
    final rows = await db.select(
      '''
      SELECT name, region, country, latitude, longitude, population
      FROM locations
      WHERE $where
      ORDER BY population DESC, name ASC
      LIMIT ?
      ''',
      args,
    );

    return rows.map((r) => GazetteerPlace.fromDbMap(r)).toList();
  }
}
