import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:mydatastudio/app_logger.dart';
import 'package:mydatastudio/database_manager.dart';
import 'package:mydatastudio/modules/search/models/place.dart';

/// Reads and populates the `places` gazetteer.
///
/// `near:banff` needs one *forward* geocode per query — a name turned into a
/// centre point — and nothing else. Photos are never geocoded. Reverse
/// geocoding every image to a place name and comparing names is the tempting
/// alternative and it structurally cannot work: it yields one nearest-town
/// label per photo, so a shot taken 12 km outside Banff resolves to some
/// neighbouring hamlet and `near:banff` silently misses it. A radius is not
/// recoverable from a name comparison.
class PlaceRepository {
  final AppDatabase db;
  final AppLogger logger = AppLogger(null);

  PlaceRepository(this.db);

  /// The bundled GeoNames `cities5000` extract. See `assets/gazetteer/`.
  static const assetPath = 'assets/gazetteer/cities5000.tsv.gz';

  /// The most likely place called [name], or null if none is.
  ///
  /// Ties break on population, because there are dozens of Springfields and
  /// the biggest is nearly always the one meant. Matching is exact rather than
  /// prefix: a prefix match on a short term ("san") would resolve to whichever
  /// large city happened to sort first and then constrain the whole query to a
  /// radius around it, which is far worse than not matching at all — an
  /// unresolved `near:` falls through to free text and still finds something.
  Future<Place?> resolve(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;

    final rows = await db.select(
      '''
      SELECT id, name, ascii_name, latitude, longitude, country, admin1,
             population
      FROM places
      WHERE name = ? COLLATE NOCASE OR ascii_name = ? COLLATE NOCASE
      ORDER BY population DESC
      LIMIT 1
      ''',
      [trimmed, trimmed],
    );
    if (rows.isEmpty) return null;
    return Place.fromMap(rows.first);
  }

  Future<int> count() async {
    final rows = await db.select('SELECT COUNT(*) AS c FROM places');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Loads the bundled gazetteer if `places` is empty, and returns how many
  /// rows it wrote.
  ///
  /// Emptiness is the gate rather than `PRAGMA user_version`: that counter is
  /// already carrying two unrelated migrations, and "is the gazetteer loaded"
  /// is answerable directly. It also self-heals — swapping the asset for a
  /// denser tier later means deleting the rows, not inventing a version number.
  ///
  /// [loadAsset] exists so tests can supply their own data; production reads
  /// the bundle, which is why this cannot live in `initSchema` — scanner
  /// isolates open their own [AppDatabase] with no Flutter binding to read
  /// assets through.
  Future<int> importIfEmpty({Future<Uint8List> Function()? loadAsset}) async {
    if (await count() > 0) return 0;

    final Uint8List bytes;
    try {
      bytes = await (loadAsset ?? _loadBundledAsset)();
    } catch (e) {
      // A missing gazetteer costs `near:` and nothing else — every other kind
      // of search still works — so this must not take the database open down
      // with it.
      logger.w('PlaceRepository: gazetteer asset unavailable, near: disabled: $e');
      return 0;
    }

    final stopwatch = Stopwatch()..start();
    final rows = _parse(gzip.decode(bytes));
    if (rows.isEmpty) {
      logger.w('PlaceRepository: gazetteer parsed to zero rows');
      return 0;
    }

    // One transaction for the whole file: partway-loaded is the one state that
    // would be actively misleading, since `near:banff` would resolve to nothing
    // and quietly demote itself to free text rather than reporting a problem.
    await db.transaction((tx) async {
      // Batched because 69,572 single-row statements is dominated by round-trip
      // overhead. 100 rows is 800 bound parameters, comfortably inside
      // SQLITE_MAX_VARIABLE_NUMBER even on the older 999 limit.
      const batchSize = 100;
      for (var start = 0; start < rows.length; start += batchSize) {
        final batch = rows.skip(start).take(batchSize).toList();
        final values = List.filled(
          batch.length,
          '(?, ?, ?, ?, ?, ?, ?, ?)',
        ).join(', ');
        await tx.execute(
          'INSERT OR REPLACE INTO places '
          '(id, name, ascii_name, latitude, longitude, country, admin1, '
          'population) VALUES $values',
          [for (final row in batch) ...row],
        );
      }
    });

    logger.i(
      'PlaceRepository: loaded ${rows.length} places in '
      '${stopwatch.elapsedMilliseconds}ms',
    );
    return rows.length;
  }

  static Future<Uint8List> _loadBundledAsset() async {
    final data = await rootBundle.load(assetPath);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Splits the trimmed GeoNames TSV into bound-parameter rows.
  ///
  /// Malformed lines are skipped rather than thrown on. The file is an asset
  /// shipped with the app, so a bad line means a bad build — but failing the
  /// whole import over one row would disable `near:` entirely rather than lose
  /// one town.
  static List<List<Object?>> _parse(List<int> tsv) {
    final rows = <List<Object?>>[];
    for (final line in const LineSplitter().convert(utf8.decode(tsv))) {
      if (line.isEmpty) continue;
      final f = line.split('\t');
      if (f.length < 8) continue;
      final id = int.tryParse(f[0]);
      final lat = double.tryParse(f[3]);
      final lng = double.tryParse(f[4]);
      if (id == null || lat == null || lng == null) continue;
      rows.add([
        id,
        f[1],
        f[2],
        lat,
        lng,
        f[5].isEmpty ? null : f[5],
        f[6].isEmpty ? null : f[6],
        int.tryParse(f[7]),
      ]);
    }
    return rows;
  }
}
