import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import '../../models/user_location.dart';

abstract class LocationEvent extends Equatable {
  const LocationEvent();
  @override
  List<Object> get props => [];
}

class AddUserLocation extends LocationEvent {
  final LatLng position;
  final String address;
  const AddUserLocation(this.position, {this.address = ''});
  @override
  List<Object> get props => [position.latitude, position.longitude];
}

class RemoveUserLocation extends LocationEvent {
  final String id;
  const RemoveUserLocation(this.id);
  @override
  List<Object> get props => [id];
}

class UpdateTravelMode extends LocationEvent {
  final String id;
  final TravelMode travelMode;
  const UpdateTravelMode(this.id, this.travelMode);
  @override
  List<Object> get props => [id, travelMode];
}

class UpdateUserAddress extends LocationEvent {
  final String id;
  final LatLng position;
  final String address;
  const UpdateUserAddress(this.id, this.position, this.address);
  @override
  List<Object> get props => [id, address];
}

class ClearAllLocations extends LocationEvent {}