import 'package:equatable/equatable.dart';
import '../../models/user_location.dart';

abstract class OptimizationEvent extends Equatable {
  const OptimizationEvent();
  @override
  List<Object> get props => [];
}

class RunOptimization extends OptimizationEvent {
  final List<UserLocation> users;
  const RunOptimization(this.users);
  @override
  List<Object> get props => [users];
}

class ResetOptimization extends OptimizationEvent {}