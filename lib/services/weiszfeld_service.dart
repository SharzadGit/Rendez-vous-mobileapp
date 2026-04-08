import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/user_location.dart';
import '../models/rendezvous_point.dart';
import '../repositories/routing_repository.dart';

class WeiszfeldService {
  final RoutingRepository _repo;

  WeiszfeldService(this._repo);

  static const int _maxIterations = 8;
  static const double _convergenceThreshold = 0.01; // km

  Future<RendezvousPoint> optimize({
    required List<UserLocation> users,
    void Function(int iteration, LatLng current)? onProgress,
  }) async {
    // Step 1 — compute geographic centroid as starting point
    final centroid = _computeCentroid(users);

    // Step 2 — get centroid fairness score for comparison later
    final centroidTimes = await _repo.getTravelTimes(
  users: users,
  candidate: centroid,
);
final centroidScore = centroidTimes.any((t) => t <= 0)
    ? 0.0
    : _fairnessScore(centroidTimes);

    // Step 3 — run Weiszfeld from multiple starting points
    //           take the best result (guards against local minima)
    final starts = [centroid];

    RendezvousPoint? best;

    for (final start in starts) {
      final result = await _runWeiszfeld(
        users: users,
        start: start,
        centroid: centroid,
        centroidScore: centroidScore,
        onProgress: onProgress,
      );
      if (best == null || result.fairnessScore > best.fairnessScore) {
        best = result;
      }
    }

    return best!;
  }

  Future<RendezvousPoint> _runWeiszfeld({
    required List<UserLocation> users,
    required LatLng start,
    required LatLng centroid,
    required double centroidScore,
    void Function(int, LatLng)? onProgress,
  }) async {
    LatLng current = start;
    List<double> currentTimes = [];
    int iteration = 0;

    for (iteration = 0; iteration < _maxIterations; iteration++) {
      onProgress?.call(iteration + 1, current);

      // Query real travel times from ORS
      currentTimes = await _repo.getTravelTimes(
      users: users,
      candidate: current,
  );
  await Future.delayed(const Duration(milliseconds: 1500));

      // Compute weights: 1 / travelTime
      // Guard against zero travel time (user already at candidate)
      final weights = currentTimes.map((t) => t < 1 ? 1.0 : t).toList();
      final totalWeight = weights.reduce((a, b) => a + b);

      // Compute new weighted centroid
      double newLat = 0;
      double newLng = 0;
      for (int i = 0; i < users.length; i++) {
        newLat += users[i].position.latitude * weights[i];
        newLng += users[i].position.longitude * weights[i];
      }
      newLat /= totalWeight;
      newLng /= totalWeight;

      final next = LatLng(newLat, newLng);

      // Check convergence
      final moved = _haversineKm(current, next);
      current = next;

      if (moved < _convergenceThreshold) break;
    }

    return RendezvousPoint(
      position: current,
      travelTimes: currentTimes,
      fairnessScore: _fairnessScore(currentTimes),
      iterations: iteration,
      centroid: centroid,
      centroidFairnessScore: centroidScore,
    );
  }

  // Geographic centroid — simple average of lat/lng
  LatLng _computeCentroid(List<UserLocation> users) {
    final lat = users.map((u) => u.position.latitude).reduce((a, b) => a + b)
        / users.length;
    final lng = users.map((u) => u.position.longitude).reduce((a, b) => a + b)
        / users.length;
    return LatLng(lat, lng);
  }

  // Fairness score: 100 - coefficient of variation (%)
  double _fairnessScore(List<double> times) {
  if (times.isEmpty) return 0;
  if (times.length == 1) return 100;
  final mean = times.reduce((a, b) => a + b) / times.length;
  if (mean == 0) return 100;
  final variance = times
      .map((t) => pow(t - mean, 2))
      .reduce((a, b) => a + b) / times.length;
  final sd = sqrt(variance);
  final cv = (sd / mean) * 100;
  return max(0, 100 - cv);
}

  // Haversine distance in km between two points
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