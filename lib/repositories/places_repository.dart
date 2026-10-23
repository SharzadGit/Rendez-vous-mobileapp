import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/nearby_place.dart';

class PlacesRepository {
  static const _overpassUrl = 'https://overpass-api.de/api/interpreter';

  Future<List<NearbyPlace>> fetchNearby({
    required LatLng point,
    required String type, // 'cafe', 'restaurant', 'park'
    double radiusMeters = 1200,
  }) async {
    final query = _buildQuery(point, type, radiusMeters);

    final response = await http.post(
      Uri.parse(_overpassUrl),
      headers: {
        'User-Agent': 'RendezvousResearchApp/1.0 (final-year-project)',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: query,
    );

    if (response.statusCode != 200) {
      throw Exception('Overpass error: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    final elements = data['elements'] as List;

    final places = elements
        .where((e) => e['tags']?['name'] != null)
        .map((e) {
          final lat = (e['lat'] as num?)?.toDouble() ??
              (e['center']?['lat'] as num?)?.toDouble() ??
              0.0;
          final lng = (e['lon'] as num?)?.toDouble() ??
              (e['center']?['lon'] as num?)?.toDouble() ??
              0.0;

          return NearbyPlace(
            name: e['tags']['name'],
            type: type,
            lat: lat,
            lng: lng,
            distanceKm: _haversineKm(point, LatLng(lat, lng)),
          );
        })
        .where((p) => p.lat != 0.0 && p.lng != 0.0)
        .toList()
      ..sort((a, b) => a.distanceKm.compareTo(b.distanceKm));

    return places.take(10).toList();
  }

  String _buildQuery(LatLng point, String type, double radius) {
    final lat = point.latitude;
    final lng = point.longitude;

    final osmTag = type == 'park'
        ? '''
          node["leisure"="park"](around:$radius,$lat,$lng);
          way["leisure"="park"](around:$radius,$lat,$lng);
          '''
        : 'node["amenity"="$type"](around:$radius,$lat,$lng);';

    return '''
[out:json][timeout:25];
(
  $osmTag
);
out center;
''';
  }

  double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _toRad(b.latitude - a.latitude);
    final dLng = _toRad(b.longitude - a.longitude);
    final sinLat = sin(dLat / 2);
    final sinLng = sin(dLng / 2);
    final h = sinLat * sinLat +
        cos(_toRad(a.latitude)) * cos(_toRad(b.latitude)) * sinLng * sinLng;
    return 2 * r * asin(sqrt(h));
  }

  double _toRad(double deg) => deg * pi / 180;
}