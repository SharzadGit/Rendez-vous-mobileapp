import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';

abstract class PlacesEvent extends Equatable {
  const PlacesEvent();
  @override
  List<Object> get props => [];
}

class FetchPlaces extends PlacesEvent {
  final LatLng point;
  final String type;
  const FetchPlaces(this.point, this.type);
  @override
  List<Object> get props => [point.latitude, point.longitude, type];
}

class ClearPlaces extends PlacesEvent {}