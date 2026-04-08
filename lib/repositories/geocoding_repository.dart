import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/place_suggestion.dart';

class GeocodingRepository {
  static const _baseUrl = 'https://nominatim.openstreetmap.org/search';

  Future<List<PlaceSuggestion>> search(String query) async {
    if (query.trim().length < 3) return [];

    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'q': query,
      'format': 'json',
      'limit': '6',
      'countrycodes': 'in',
      'addressdetails': '1',
    });

    final response = await http.get(uri, headers: {
      'User-Agent': 'rendezvous_app/1.0',
    });

    if (response.statusCode != 200) return [];

    final data = jsonDecode(response.body) as List;

    return data.map((item) {
      final address = item['address'] as Map<String, dynamic>? ?? {};

      // Build a short readable name
      final shortName = _buildShortName(item['display_name'], address);

      return PlaceSuggestion(
        displayName: item['display_name'],
        shortName: shortName,
        position: LatLng(
          double.parse(item['lat']),
          double.parse(item['lon']),
        ),
      );
    }).toList();
  }

  String _buildShortName(String displayName, Map<String, dynamic> address) {
    // Try to get a meaningful short name
    final name = address['amenity'] ??
        address['road'] ??
        address['neighbourhood'] ??
        address['suburb'] ??
        address['city_district'];

    final area = address['suburb'] ??
        address['city_district'] ??
        address['city'] ??
        '';

    if (name != null && area.isNotEmpty && name != area) {
      return '$name, $area';
    }
    if (name != null) return name;

    // Fall back to first two parts of display name
    final parts = displayName.split(',');
    if (parts.length >= 2) {
      return '${parts[0].trim()}, ${parts[1].trim()}';
    }
    return displayName;
  }
}