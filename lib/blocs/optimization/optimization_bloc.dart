import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/routing_repository.dart';
import '../../services/weiszfeld_service.dart';
import 'optimization_event.dart';
import 'optimization_state.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

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
    await WakelockPlus.enable(); // Keep device awake

    await _service.optimize(
      users: event.users,
      onProgress: (iteration, point) {
        emit(OptimizationRunning(iteration, point));
      },
    ).then((result) {
      emit(OptimizationSuccess(result));
    });
  } catch (e) {
    emit(OptimizationFailure(e.toString()));
  } finally {
    await WakelockPlus.disable(); // Release wakelock
  }
}

  void _onReset(ResetOptimization event, Emitter<OptimizationState> emit) {
    emit(OptimizationInitial());
  }
}