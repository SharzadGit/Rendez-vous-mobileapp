import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../../models/user_location.dart';
import 'location_event.dart';
import 'location_state.dart';

const _uuid = Uuid();

const _pinColors = [
  Colors.red,
  Colors.blue,
  Colors.green,
  Colors.orange,
  Colors.purple,
  Colors.teal,
];

class LocationBloc extends Bloc<LocationEvent, LocationState> {
  LocationBloc() : super(const LocationState()) {
    on<AddUserLocation>(_onAdd);
    on<RemoveUserLocation>(_onRemove);
    on<UpdateTravelMode>(_onUpdateMode);
    on<UpdateUserAddress>(_onUpdateAddress);
    on<ClearAllLocations>(_onClear);
  }

  void _onAdd(AddUserLocation event, Emitter<LocationState> emit) {
    final newUser = UserLocation(
      id: _uuid.v4(),
      position: event.position,
      color: _pinColors[state.users.length % _pinColors.length],
      travelMode: TravelMode.driving,
      address: event.address,
    );
    emit(state.copyWith(users: [...state.users, newUser]));
  }

  void _onRemove(RemoveUserLocation event, Emitter<LocationState> emit) {
    emit(state.copyWith(
      users: state.users.where((u) => u.id != event.id).toList(),
    ));
  }

  void _onUpdateMode(UpdateTravelMode event, Emitter<LocationState> emit) {
    emit(state.copyWith(
      users: state.users.map((u) {
        return u.id == event.id ? u.copyWith(travelMode: event.travelMode) : u;
      }).toList(),
    ));
  }

  void _onUpdateAddress(UpdateUserAddress event, Emitter<LocationState> emit) {
    emit(state.copyWith(
      users: state.users.map((u) {
        return u.id == event.id
            ? u.copyWith(position: event.position, address: event.address)
            : u;
      }).toList(),
    ));
  }

  void _onClear(ClearAllLocations event, Emitter<LocationState> emit) {
    emit(const LocationState());
  }
}