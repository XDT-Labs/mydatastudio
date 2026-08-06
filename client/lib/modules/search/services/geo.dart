import 'dart:math' as math;

/// The rectangle a radius search scans before measuring exact distances.
///
/// Longitude spans the whole globe when the radius would cross a pole or the
/// antimeridian — see [GeoRadius.boundingBox].
class GeoBox {
  final double minLatitude;
  final double maxLatitude;
  final double minLongitude;
  final double maxLongitude;

  const GeoBox({
    required this.minLatitude,
    required this.maxLatitude,
    required this.minLongitude,
    required this.maxLongitude,
  });

  @override
  String toString() =>
      'GeoBox(lat $minLatitude..$maxLatitude, lng $minLongitude..$maxLongitude)';
}

/// Radius search over the `latitude`/`longitude` columns on `files`.
///
/// Two stages, and the split is the whole point. resqlite's SQLite has
/// `SQLITE_ENABLE_MATH_FUNCTIONS` but no R-Tree, so there is no spatial index
/// to range-scan. A `BETWEEN` on both coordinate columns *can* use an ordinary
/// index and throws away almost everything cheaply; haversine then measures
/// what survives. Running haversine alone would work and would be exact, it
/// would just compute six trig functions for every georeferenced row.
class GeoRadius {
  static const double earthRadiusKm = 6371.0;

  /// Kilometres per degree of latitude. Constant everywhere, unlike longitude.
  static const double kmPerDegreeLatitude = 111.32;

  /// The smallest latitude/longitude rectangle containing every point within
  /// [radiusKm] of ([latitude], [longitude]).
  ///
  /// A rectangle in degrees always *over*-covers a circle in kilometres, which
  /// is the safe direction: the haversine filter that follows removes the
  /// corners. Being generous here can only cost a few extra distance
  /// computations, whereas being tight by a rounding error would drop a
  /// genuine match with no way to notice.
  static GeoBox boundingBox(double latitude, double longitude, double radiusKm) {
    final deltaLat = radiusKm / kmPerDegreeLatitude;
    final minLat = latitude - deltaLat;
    final maxLat = latitude + deltaLat;

    // A degree of longitude shrinks towards the poles, so the same radius spans
    // more of them the further north or south the centre is — and at the pole
    // itself the divisor reaches zero. Once the box would reach past a pole,
    // or wrap across the antimeridian, `BETWEEN` cannot express the range as
    // one interval: -181 and +181 are outside every stored value's domain, so
    // the clause would exclude exactly the points nearest the wrap. Widen to
    // the full range instead and let haversine do all the filtering. This is
    // rare enough (polar and dateline photos) that losing the prefilter there
    // costs nothing measurable.
    final cosLat = math.cos(_radians(latitude));
    if (minLat <= -90.0 || maxLat >= 90.0 || cosLat.abs() < 1e-9) {
      return GeoBox(
        minLatitude: math.max(minLat, -90.0),
        maxLatitude: math.min(maxLat, 90.0),
        minLongitude: -180.0,
        maxLongitude: 180.0,
      );
    }

    final deltaLng = radiusKm / (kmPerDegreeLatitude * cosLat.abs());
    if (deltaLng >= 180.0 ||
        longitude - deltaLng < -180.0 ||
        longitude + deltaLng > 180.0) {
      return GeoBox(
        minLatitude: minLat,
        maxLatitude: maxLat,
        minLongitude: -180.0,
        maxLongitude: 180.0,
      );
    }

    return GeoBox(
      minLatitude: minLat,
      maxLatitude: maxLat,
      minLongitude: longitude - deltaLng,
      maxLongitude: longitude + deltaLng,
    );
  }

  /// Great-circle distance in kilometres. The Dart twin of [haversineSql],
  /// kept so the SQL can be checked against something independently derived.
  static double distanceKm(
    double lat1,
    double lng1,
    double lat2,
    double lng2,
  ) {
    final cosine =
        math.cos(_radians(lat1)) *
            math.cos(_radians(lat2)) *
            math.cos(_radians(lng2) - _radians(lng1)) +
        math.sin(_radians(lat1)) * math.sin(_radians(lat2));
    return earthRadiusKm * math.acos(cosine.clamp(-1.0, 1.0));
  }

  /// A SQL expression for the distance in kilometres from a bound centre point
  /// to `$latColumn`/`$lngColumn`, taking `?, ?` (latitude, longitude) — in
  /// that order, twice each.
  ///
  /// The `min(1.0, ...)` is not defensive decoration. For a point at zero
  /// distance the cosine terms sum to something a hair above 1.0 in floating
  /// point, `acos` of which is `NaN`, and every comparison against `NaN` is
  /// false — so without the clamp the row that matched *best* is the one row
  /// silently dropped.
  static String haversineSql(String latColumn, String lngColumn) {
    return '($earthRadiusKm * acos(min(1.0, '
        'cos(radians(?)) * cos(radians($latColumn)) '
        '* cos(radians($lngColumn) - radians(?)) '
        '+ sin(radians(?)) * sin(radians($latColumn))'
        ')))';
  }

  /// Parameters for [haversineSql], in the order its `?` placeholders appear.
  static List<Object?> haversineParams(double latitude, double longitude) {
    return [latitude, longitude, latitude];
  }

  static double _radians(double degrees) => degrees * math.pi / 180.0;
}
