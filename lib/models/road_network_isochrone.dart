import 'package:latlong2/latlong.dart';
import 'user_location.dart';

/// An ORS response plus the exact inputs needed to identify this reachable area.
///
/// GeoJSON positions remain [longitude, latitude, ...]. Polygon rings, holes,
/// MultiPolygon components, properties and provider metadata are retained.
class RoadNetworkIsochrone {
  final LatLng origin;
  final TravelMode travelMode;
  final Duration travelTime;
  final Map<String, dynamic> geoJson;

  RoadNetworkIsochrone({
    required this.origin,
    required this.travelMode,
    required this.travelTime,
    required Map<String, dynamic> geoJson,
  }) : geoJson = _freeze(geoJson) as Map<String, dynamic>;

  static dynamic _freeze(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
        value.map((key, value) => MapEntry(key, _freeze(value))),
      );
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }
}
