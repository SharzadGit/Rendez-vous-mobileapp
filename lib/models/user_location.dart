import 'package:latlong2/latlong.dart';
import 'package:flutter/material.dart';

enum TravelMode { driving, twoWheeler, walking }

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