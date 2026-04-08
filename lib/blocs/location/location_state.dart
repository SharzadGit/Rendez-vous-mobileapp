import 'package:equatable/equatable.dart';
import '../../models/user_location.dart';

class LocationState extends Equatable {
  final List<UserLocation> users;

  const LocationState({this.users = const []});

  LocationState copyWith({List<UserLocation>? users}) {
    return LocationState(users: users ?? this.users);
  }

  @override
  List<Object> get props => [users];
}