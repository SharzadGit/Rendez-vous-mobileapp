import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/routing_repository.dart';
import '../../models/user_location.dart';
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
    final users = List<UserLocation>.unmodifiable(event.users);
    await WakelockPlus.enable(); // Keep device awake

    await _service.optimize(
      users: users,
      onProgress: (iteration, point) {
        emit(OptimizationRunning(iteration, point));
      },
    ).then((result) {
      emit(OptimizationSuccess(result, users));
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
