import 'package:latlong2/latlong.dart';
import 'package:flutter/material.dart';
import '../models/user_location.dart';
import 'routing_repository.dart';

Future<void> testRouting() async {
  final repo = RoutingRepository();

  final users = [
    UserLocation(
      id: '1',
      position: const LatLng(12.9716, 77.5946), // Bangalore city center
      color: Colors.red,
      travelMode: TravelMode.driving,
    ),
    UserLocation(
      id: '2',
      position: const LatLng(12.9352, 77.6245), // Koramangala
      color: Colors.blue,
      travelMode: TravelMode.twoWheeler,
    ),
    UserLocation(
      id: '3',
      position: const LatLng(13.0100, 77.5500), // Yeshwanthpur
      color: Colors.green,
      travelMode: TravelMode.walking,
    ),
  ];

  final candidate = const LatLng(12.9698, 77.5950); // test midpoint

  print('Calling ORS...');
  final times = await repo.getTravelTimes(users: users, candidate: candidate);

  for (int i = 0; i < times.length; i++) {
    print('Person ${i + 1}: ${(times[i] / 60).toStringAsFixed(1)} mins');
  }
}