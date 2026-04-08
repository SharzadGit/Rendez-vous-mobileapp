import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/user_location.dart';
import '../config/api_keys.dart';

class RoutingRepository {
  static const _baseUrl = 'https://api.openrouteservice.org/v2/matrix';

  // Maps our TravelMode to ORS endpoint segment
  String _orsProfile(TravelMode mode) {
    switch (mode) {
      case TravelMode.driving:
        return 'driving-car';
      case TravelMode.twoWheeler:
        return 'cycling-regular';
      case TravelMode.walking:
        return 'foot-walking';
    }
  }

  /// Returns travel times in seconds from each user to the candidate point.
  /// Result is a list where result[i] = seconds from user i to candidate.
  Future<List<double>> getTravelTimes({
    required List<UserLocation> users,
    required LatLng candidate,
  }) async {
    // ORS matrix requires all users to share the same travel mode.
    // We call the API once per unique travel mode and stitch results together.
    final results = List<double>.filled(users.length, 0);

    final byMode = <TravelMode, List<int>>{};
    for (int i = 0; i < users.length; i++) {
      byMode.putIfAbsent(users[i].travelMode, () => []).add(i);
    }

    for (final entry in byMode.entries) {
      final mode = entry.key;
      final indices = entry.value;
      final modeUsers = indices.map((i) => users[i]).toList();

      final times = await _fetchMatrix(
        mode: mode,
        users: modeUsers,
        candidate: candidate,
      );

      for (int j = 0; j < indices.length; j++) {
        results[indices[j]] = times[j];
      }
    }

    return results;
  }

  Future<List<double>> _fetchMatrix({
    required TravelMode mode,
    required List<UserLocation> users,
    required LatLng candidate,
  }) async {
    final profile = _orsProfile(mode);

    // Coordinates: all users first, then the candidate point last
    final locations = [
      ...users.map((u) => [u.position.longitude, u.position.latitude]),
      [candidate.longitude, candidate.latitude],
    ];

    // sources = all user indices, destinations = candidate index (last)
    final sources = List.generate(users.length, (i) => i);
    final destinations = [users.length];

    final url = Uri.parse('$_baseUrl/$profile');
    final response = await http.post(
      url,
      headers: {
        'Authorization': ApiKeys.ors,
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'locations': locations,
        'sources': sources,
        'destinations': destinations,
        'metrics': ['duration'],
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('ORS API error ${response.statusCode}: ${response.body}');
    }

    final data = jsonDecode(response.body);
    // durations is a 2D array: [source][destination]
    // We only have one destination so it's [[t0], [t1], [t2]...]
    final durations = data['durations'] as List;
    return durations.map((row) => (row[0] as num).toDouble()).toList();
  }
}