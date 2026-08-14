/// One row of the embedded gazetteer — a populated place the user can search
/// for to find photos taken near it.
class GazetteerPlace {
  const GazetteerPlace({
    required this.name,
    required this.country,
    required this.latitude,
    required this.longitude,
    this.region,
    this.population = 0,
  });

  final String name;

  /// State/province, when GeoNames has one for this place.
  final String? region;

  final String country;
  final double latitude;
  final double longitude;

  /// Drives result ordering — a search for "springfield" should offer the
  /// one a million people live in before the one nine hundred do.
  final int population;

  /// `Austin, Texas, United States`
  String get label => [
    name,
    if (region != null && region!.isNotEmpty && region != name) region!,
    country,
  ].join(', ');

  factory GazetteerPlace.fromDbMap(Map<String, dynamic> map) {
    return GazetteerPlace(
      name: map['name'] as String,
      region: map['region'] as String?,
      country: map['country'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      population: (map['population'] as int?) ?? 0,
    );
  }
}
