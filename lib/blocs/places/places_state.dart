import 'package:equatable/equatable.dart';
import '../../models/nearby_place.dart';

abstract class PlacesState extends Equatable {
  const PlacesState();
  @override
  List<Object> get props => [];
}

class PlacesInitial extends PlacesState {}

class PlacesLoading extends PlacesState {}

class PlacesSuccess extends PlacesState {
  final List<NearbyPlace> places;
  final String type;
  const PlacesSuccess(this.places, this.type);
  @override
  List<Object> get props => [places, type];
}

class PlacesFailure extends PlacesState {
  final String message;
  const PlacesFailure(this.message);
  @override
  List<Object> get props => [message];
}