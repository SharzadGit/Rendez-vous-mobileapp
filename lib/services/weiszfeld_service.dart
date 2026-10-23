import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/user_location.dart';
import '../models/rendezvous_point.dart';
import '../repositories/routing_repository.dart';

class WeiszfeldService {
  final RoutingRepository _repo;

  WeiszfeldService(this._repo);

  static const int _maxIterations = 10;
  static const double _convergenceThreshold = 0.008;

  Future<RendezvousPoint> optimize({
    required List<UserLocation> users,
    void Function(int iteration, LatLng current)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    final centroid = _computeCentroid(users);

    // Evaluate centroid first
    final centroidTimes =
        await _repo.getTravelTimes(users: users, candidate: centroid);
    final centroidMetrics = _computeMetrics(centroidTimes);
    final centroidScore = _fairnessScore(centroidTimes);

    // Run geometric Weiszfeld
    LatLng current = centroid;
    int iteration = 0;

    for (iteration = 0; iteration < _maxIterations; iteration++) {
      onProgress?.call(iteration + 1, current);

      final weights = <double>[];
      for (final user in users) {
        final dist = _haversineKm(current, user.position);
        weights.add(dist < 0.001 ? 1e6 : 1.0 / dist);
      }

      final totalWeight = weights.reduce((a, b) => a + b);
      double newLat = 0;
      double newLng = 0;

      for (int i = 0; i < users.length; i++) {
        newLat += users[i].position.latitude * weights[i];
        newLng += users[i].position.longitude * weights[i];
      }

      final next = LatLng(newLat / totalWeight, newLng / totalWeight);
      final moved = _haversineKm(current, next);
      current = next;

      if (moved < _convergenceThreshold) break;
      await Future.delayed(const Duration(milliseconds: 150));
    }

    // Lighter local search (fewer candidates)
    final candidates = <LatLng>[
      current, // geometric median
      centroid,
    ];

    const distances = [0.005, 0.01];
    for (final d in distances) {
      candidates.add(LatLng(current.latitude + d, current.longitude));
      candidates.add(LatLng(current.latitude - d, current.longitude));
      candidates.add(LatLng(current.latitude, current.longitude + d));
      candidates.add(LatLng(current.latitude, current.longitude - d));
    }

    RendezvousPoint? best;
    double bestScore = -999999;

    for (final candidate in candidates) {
      final times =
          await _repo.getTravelTimes(users: users, candidate: candidate);
      await Future.delayed(const Duration(milliseconds: 1000));

      final metrics = _computeMetrics(times);
      final fairness = _fairnessScore(times);

      final score = (fairness * 2.0) - (metrics['max']! / 60.0) * 1.2;

      if (score > bestScore) {
        bestScore = score;
        best = RendezvousPoint(
          position: candidate,
          travelTimes: times,
          fairnessScore: fairness,
          iterations: iteration + 1,
          centroid: centroid,
          centroidFairnessScore: centroidScore,
          totalTravelTime: metrics['total']!,
          meanTravelTime: metrics['mean']!,
          maxTravelTime: metrics['max']!,
          stdDevTravelTime: metrics['sd']!,
          centroidTotalTravelTime: centroidMetrics['total']!,
          centroidMaxTravelTime: centroidMetrics['max']!,
          improvementInFairness: fairness - centroidScore,
          hybridScore: _hybridScore(
            mean: metrics['mean']!,
            sd: metrics['sd']!,
            centroidMean: centroidMetrics['mean']!,
            centroidSd: centroidMetrics['sd']!,
          ),
          computationTime: stopwatch.elapsed,
        );
      }
    }

    return best!;
  }

  Map<String, double> _computeMetrics(List<double> times) {
    if (times.isEmpty) return {'total': 0, 'mean': 0, 'max': 0, 'sd': 0};

    final total = times.reduce((a, b) => a + b);
    final mean = total / times.length;
    final maxT = times.reduce((a, b) => a > b ? a : b);
    final variance =
        times.map((t) => pow(t - mean, 2)).reduce((a, b) => a + b) /
            times.length;

    return {
      'total': total,
      'mean': mean,
      'max': maxT,
      'sd': sqrt(variance),
    };
  }

  double _fairnessScore(List<double> times) {
    if (times.length <= 1) return 100;
    final mean = times.reduce((a, b) => a + b) / times.length;
    if (mean == 0) return 100;
    final variance =
        times.map((t) => pow(t - mean, 2)).reduce((a, b) => a + b) /
            times.length;
    final cv = (sqrt(variance) / mean) * 100;
    return max(0, 100 - cv);
  }

  double _hybridScore({
    required double mean,
    required double sd,
    required double centroidMean,
    required double centroidSd,
  }) {
    final normMean = centroidMean == 0 ? 0 : mean / centroidMean;
    final normSd = centroidSd == 0 ? 0 : sd / centroidSd;
    return 0.6 * normMean + 0.4 * normSd;
  }

  LatLng _computeCentroid(List<UserLocation> users) {
    final lat =
        users.map((u) => u.position.latitude).reduce((a, b) => a + b) /
            users.length;
    final lng =
        users.map((u) => u.position.longitude).reduce((a, b) => a + b) /
            users.length;
    return LatLng(lat, lng);
  }

  double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = _toRad(b.latitude - a.latitude);
    final dLng = _toRad(b.longitude - a.longitude);
    final h = pow(sin(dLat / 2), 2) +
        cos(_toRad(a.latitude)) *
            cos(_toRad(b.latitude)) *
            pow(sin(dLng / 2), 2);
    return 2 * r * asin(sqrt(h));
  }

  double _toRad(double deg) => deg * pi / 180;
}