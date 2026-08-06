/// One populated place from the bundled GeoNames gazetteer.
///
/// The only thing search needs from a place is a centre point to measure a
/// radius from; the rest is here to label it once it has been picked, so
/// `near:springfield` can say which Springfield it chose.
class Place {
  final int id;

  /// The place's own spelling, diacritics intact ("Zürich").
  final String name;

  /// The transliterated spelling ("Zurich"). Both are indexed, because a query
  /// may reasonably type either and only one of them is on an English keyboard.
  final String asciiName;

  final double latitude;
  final double longitude;

  /// ISO country code.
  final String? country;

  /// GeoNames admin1 (state/province) *code*, not its name — decoding it needs
  /// a second GeoNames file that is not bundled. Stored rather than displayed,
  /// so a future disambiguation chip can tell two same-country namesakes apart
  /// without a re-import.
  final String? admin1;

  final int? population;

  const Place({
    required this.id,
    required this.name,
    required this.asciiName,
    required this.latitude,
    required this.longitude,
    this.country,
    this.admin1,
    this.population,
  });

  factory Place.fromMap(Map<String, Object?> map) {
    return Place(
      id: (map['id'] as num).toInt(),
      name: map['name'] as String,
      asciiName: map['ascii_name'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      country: map['country'] as String?,
      admin1: map['admin1'] as String?,
      population: (map['population'] as num?)?.toInt(),
    );
  }

  /// How the resolved place is shown back to the user.
  String get label => country == null || country!.isEmpty ? name : '$name, $country';

  @override
  String toString() => 'Place($label @ $latitude,$longitude)';
}
