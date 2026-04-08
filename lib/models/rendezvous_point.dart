import 'package:latlong2/latlong.dart';
import 'user_location.dart';

class RendezvousPoint {
  final LatLng position;
  final List<double> travelTimes; // seconds, one per user
  final double fairnessScore;    // 0–100
  final int iterations;
  final LatLng centroid;         // raw geographic midpoint for comparison
  final double centroidFairnessScore;

  const RendezvousPoint({
    required this.position,
    required this.travelTimes,
    required this.fairnessScore,
    required this.iterations,
    required this.centroid,
    required this.centroidFairnessScore,
  });

  // Travel time in minutes for display
  double travelMinutes(int userIndex) => travelTimes[userIndex] / 60;
}