import 'package:latlong2/latlong.dart';
import 'package:flutter/material.dart';

enum TravelMode {
  driving,
  // Legacy motorcycle-like option; never reinterpret it as a bicycle.
  twoWheeler,
  walking,
  cycling;

  static const supported = [driving, cycling, walking];

  String get orsProfile => switch (this) {
    driving => 'driving-car',
    cycling => 'cycling-regular',
    walking => 'foot-walking',
    twoWheeler => throw UnsupportedError(
      'Motorcycle/two-wheeler routing is not supported by OpenRouteService.',
    ),
  };
}

class UserLocation {
  final String id;
  final LatLng position;
  final Color color;
  final TravelMode travelMode;
  final String address; // display name, empty if tapped from map

  const UserLocation({
    required this.id,
    required this.position,
    required this.color,
    required this.travelMode,
    this.address = '',
  });

  UserLocation copyWith({
    LatLng? position,
    Color? color,
    TravelMode? travelMode,
    String? address,
  }) {
    return UserLocation(
      id: id,
      position: position ?? this.position,
      color: color ?? this.color,
      travelMode: travelMode ?? this.travelMode,
      address: address ?? this.address,
    );
  }
}
