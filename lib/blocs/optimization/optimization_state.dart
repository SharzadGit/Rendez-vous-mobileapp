import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import '../../models/rendezvous_point.dart';

abstract class OptimizationState extends Equatable {
  const OptimizationState();
  @override
  List<Object?> get props => [];
}

class OptimizationInitial extends OptimizationState {}

class OptimizationRunning extends OptimizationState {
  final int iteration;
  final LatLng currentPoint;
  const OptimizationRunning(this.iteration, this.currentPoint);
  @override
  List<Object?> get props => [iteration, currentPoint];
}

class OptimizationSuccess extends OptimizationState {
  final RendezvousPoint result;
  const OptimizationSuccess(this.result);
  @override
  List<Object?> get props => [result];
}

class OptimizationFailure extends OptimizationState {
  final String message;
  const OptimizationFailure(this.message);
  @override
  List<Object?> get props => [message];
}