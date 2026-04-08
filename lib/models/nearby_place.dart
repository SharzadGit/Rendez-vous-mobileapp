class NearbyPlace {
  final String name;
  final String type;
  final double lat;
  final double lng;
  final double distanceKm;

  const NearbyPlace({
    required this.name,
    required this.type,
    required this.lat,
    required this.lng,
    required this.distanceKm,
  });

  String get distanceText {
    if (distanceKm < 1) return '${(distanceKm * 1000).toInt()}m away';
    return '${distanceKm.toStringAsFixed(1)}km away';
  }
}