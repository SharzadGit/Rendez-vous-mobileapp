import 'package:latlong2/latlong.dart';

class PlaceSuggestion {
  final String displayName;
  final String shortName;
  final LatLng position;

  const PlaceSuggestion({
    required this.displayName,
    required this.shortName,
    required this.position,
  });
}