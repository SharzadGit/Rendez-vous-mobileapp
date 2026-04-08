import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/routing_repository.dart';
import '../../services/weiszfeld_service.dart';
import 'optimization_event.dart';
import 'optimization_state.dart';

class OptimizationBloc extends Bloc<OptimizationEvent, OptimizationState> {
  final WeiszfeldService _service;

  OptimizationBloc()
      : _service = WeiszfeldService(RoutingRepository()),
        super(OptimizationInitial()) {
    on<RunOptimization>(_onRun);
    on<ResetOptimization>(_onReset);
  }

  Future<void> _onRun(
      RunOptimization event, Emitter<OptimizationState> emit) async {
    try {
      await _service.optimize(
        users: event.users,
        onProgress: (iteration, point) {
          emit(OptimizationRunning(iteration, point));
        },
      ).then((result) {
        print('=== RESULT ===');
        print('Optimal point: ${result.position.latitude}, ${result.position.longitude}');
        print('Fairness score: ${result.fairnessScore.toStringAsFixed(1)}%');
        print('Centroid score: ${result.centroidFairnessScore.toStringAsFixed(1)}%');
        for (int i = 0; i < result.travelTimes.length; i++) {
          print('Person ${i+1}: ${result.travelMinutes(i).toStringAsFixed(1)} mins');
        }
      emit(OptimizationSuccess(result));
      });
    } catch (e) {
      emit(OptimizationFailure(e.toString()));
    }
  }

  void _onReset(ResetOptimization event, Emitter<OptimizationState> emit) {
    emit(OptimizationInitial());
  }
}