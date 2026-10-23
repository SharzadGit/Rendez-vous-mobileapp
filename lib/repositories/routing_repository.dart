import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../config/api_keys.dart';
import '../models/user_location.dart';

class RoutingRepository {
  static const _baseUrl = 'https://api.openrouteservice.org/v2/matrix/driving-car';

  /// Returns travel times in seconds from each user to the candidate point.
  Future<List<double>> getTravelTimes({
    required List<UserLocation> users,
    required LatLng candidate,
  }) async {
    if (users.isEmpty) return [];

    final locations = <List<double>>[];

    // Candidate first
    locations.add([candidate.longitude, candidate.latitude]);

    // Then all users
    for (final user in users) {
      locations.add([user.position.longitude, user.position.latitude]);
    }

    final body = jsonEncode({
      'locations': locations,
      'metrics': ['duration'],
      'units': 'm',
    });

    final response = await http.post(
      Uri.parse(_baseUrl),
      headers: {
        'Authorization': ApiKeys.ors,
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception(
          'ORS API error ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    final durations = data['durations'] as List;

    // durations[0] contains times from the candidate to all points
    // Skip index 0 (candidate to itself) and take the rest
    final times = <double>[];
    for (var i = 1; i < durations[0].length; i++) {
      final value = durations[0][i];
      times.add(value == null ? 999999.0 : (value as num).toDouble());
    }

    return times;
  }
}