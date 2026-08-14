import 'dart:math' as math;

/// "Photos taken near here" — a gazetteer place plus how far around it to look.
///
/// Kept apart from the free-text `location` filter, which matches AI-detected
/// landmark names on `file_landmarks`. This one works off the GPS coordinates
/// the scanners already read out of EXIF, which is why it finds anything at
/// all: hardly any photo has a landmark, and most have a lat/lng.
class PhotoPlaceFilter {
  const PhotoPlaceFilter({
    required this.label,
    required this.latitude,
    required this.longitude,
    this.radiusKm = defaultRadiusKm,
  });

  /// What the user picked, e.g. `Austin, Texas, United States`.
  final String label;

  final double latitude;
  final double longitude;
  final double radiusKm;

  static const double kmPerMile = 1.609344;

  /// Distances are stored in kilometres because [boundingBox] is metric, and
  /// offered in miles because that is what the people using this think in.
  static const List<double> radiusMileOptions = [1, 5, 10, 25, 50, 100, 250];

  static const double defaultRadiusMiles = 25;
  static const double defaultRadiusKm = defaultRadiusMiles * kmPerMile;

  double get radiusMiles => radiusKm / kmPerMile;

  /// The offered stop nearest [radiusKm], so the slider always rests on one
  /// even for a radius that did not come from it.
  double get nearestMileOption {
    final miles = radiusMiles;
    return radiusMileOptions.reduce(
      (a, b) => (a - miles).abs() <= (b - miles).abs() ? a : b,
    );
  }

  /// The lat/lng box to filter on.
  ///
  /// A box, not a circle: SQLite has no trigonometry to compute great-circle
  /// distance with, and a box is what the `files (latitude, longitude)` index
  /// can serve. It over-selects at the corners by up to ~41%, which for
  /// "photos near Austin" is a better failure than the alternative — a query
  /// that scans every geotagged photo in the library.
  PhotoBoundingBox get boundingBox {
    const kmPerDegreeLat = 111.045;
    final latDelta = radiusKm / kmPerDegreeLat;

    // Meridians converge toward the poles, so a kilometre is worth more
    // degrees of longitude the further north or south you are. cos() reaches 0
    // at the pole, so the clamp keeps a polar search from asking for an
    // infinite span.
    final cosLat = math.cos(latitude * math.pi / 180).abs();
    final lngDelta = cosLat < 0.01
        ? 180.0
        : math.min(180.0, radiusKm / (kmPerDegreeLat * cosLat));

    return PhotoBoundingBox(
      minLat: math.max(-90.0, latitude - latDelta),
      maxLat: math.min(90.0, latitude + latDelta),
      minLng: longitude - lngDelta,
      maxLng: longitude + lngDelta,
    );
  }

  PhotoPlaceFilter copyWith({double? radiusKm, double? radiusMiles}) {
    return PhotoPlaceFilter(
      label: label,
      latitude: latitude,
      longitude: longitude,
      radiusKm:
          radiusKm ??
          (radiusMiles != null ? radiusMiles * kmPerMile : this.radiusKm),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is PhotoPlaceFilter &&
        other.label == label &&
        other.latitude == latitude &&
        other.longitude == longitude &&
        other.radiusKm == radiusKm;
  }

  @override
  int get hashCode => Object.hash(label, latitude, longitude, radiusKm);
}

/// The lat/lng window a [PhotoPlaceFilter] selects.
class PhotoBoundingBox {
  const PhotoBoundingBox({
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });

  final double minLat;
  final double maxLat;

  /// May fall outside ±180 when the box spans the antimeridian — see
  /// [wrapsAntimeridian], which is how the query has to be written instead.
  final double minLng;
  final double maxLng;

  bool get wrapsAntimeridian => minLng < -180 || maxLng > 180;

  /// [minLng] brought back into ±180.
  double get normalizedMinLng => _normalizeLng(minLng);

  /// [maxLng] brought back into ±180.
  double get normalizedMaxLng => _normalizeLng(maxLng);

  static double _normalizeLng(double lng) {
    var value = lng;
    while (value > 180) {
      value -= 360;
    }
    while (value < -180) {
      value += 360;
    }
    return value;
  }
}
