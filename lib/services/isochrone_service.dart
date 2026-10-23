import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../models/user_location.dart';
import '../models/rendezvous_point.dart';
import '../repositories/routing_repository.dart';

class IsochroneService {
  final RoutingRepository _repo;

  IsochroneService(this._repo);

  Future<RendezvousPoint> optimize({
    required List<UserLocation> users,
    void Function(String status)? onProgress,
  }) async {
    final stopwatch = Stopwatch()..start();

    onProgress?.call('Computing centroid...');
    final centroid = _computeCentroid(users);

    final centroidTimes =
        await _repo.getTravelTimes(users: users, candidate: centroid);
    final centroidMetrics = _computeMetrics(centroidTimes);
    final centroidScore = _fairnessScore(centroidTimes);

    // Lighter candidate generation
    final candidates = <LatLng>{centroid};

    const rings = [0.006, 0.012];
    for (final r in rings) {
      for (int i = 0; i < 4; i++) {
        final angle = (i * 90) * pi / 180;
        candidates.add(LatLng(
          centroid.latitude + r * cos(angle),
          centroid.longitude + r * sin(angle),
        ));
      }
    }

    // One midpoint toward the farthest user
    if (users.isNotEmpty) {
      final farthest = users.reduce((a, b) =>
          _haversineKm(centroid, a.position) >
                  _haversineKm(centroid, b.position)
              ? a
              : b);
      candidates.add(LatLng(
        (centroid.latitude + farthest.position.latitude) / 2,
        (centroid.longitude + farthest.position.longitude) / 2,
      ));
    }

    onProgress?.call('Evaluating ${candidates.length} candidates...');

    RendezvousPoint? best;
    double bestMaxTime = double.infinity;

    int evaluated = 0;
    for (final candidate in candidates) {
      evaluated++;
      if (evaluated % 3 == 0) {
        onProgress?.call(
            'Evaluating candidates ($evaluated/${candidates.length})...');
      }

      final times =
          await _repo.getTravelTimes(users: users, candidate: candidate);
      await Future.delayed(const Duration(milliseconds: 1100));

      final metrics = _computeMetrics(times);
      final maxTime = metrics['max']!;

      if (maxTime < bestMaxTime - 1.0 ||
          (maxTime <= bestMaxTime + 15 &&
              _fairnessScore(times) > (best?.fairnessScore ?? 0))) {
        bestMaxTime = maxTime;

        final fairness = _fairnessScore(times);

        best = RendezvousPoint(
          position: candidate,
          travelTimes: times,
          fairnessScore: fairness,
          iterations: evaluated,
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
        );
      }
    }

    stopwatch.stop();
    onProgress?.call('Done in ${stopwatch.elapsed.inSeconds}s');

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