import 'package:latlong2/latlong.dart';

class RendezvousPoint {
  final LatLng position;
  final List<double> travelTimes; // seconds
  final double fairnessScore; // 0–100
  final int iterations;
  final LatLng centroid;
  final double centroidFairnessScore;

  // Research metrics
  final double totalTravelTime;
  final double meanTravelTime;
  final double maxTravelTime;
  final double stdDevTravelTime;
  final double centroidTotalTravelTime;
  final double centroidMaxTravelTime;
  final double improvementInFairness;
  final double hybridScore;

  // New field for real computation time
  final Duration? computationTime;

  const RendezvousPoint({
    required this.position,
    required this.travelTimes,
    required this.fairnessScore,
    required this.iterations,
    required this.centroid,
    required this.centroidFairnessScore,
    required this.totalTravelTime,
    required this.meanTravelTime,
    required this.maxTravelTime,
    required this.stdDevTravelTime,
    required this.centroidTotalTravelTime,
    required this.centroidMaxTravelTime,
    required this.improvementInFairness,
    required this.hybridScore,
    this.computationTime,
  });

  double travelMinutes(int userIndex) => travelTimes[userIndex] / 60;

  double get totalMinutes => totalTravelTime / 60;
  double get meanMinutes => meanTravelTime / 60;
  double get maxMinutes => maxTravelTime / 60;
  double get stdDevMinutes => stdDevTravelTime / 60;
}