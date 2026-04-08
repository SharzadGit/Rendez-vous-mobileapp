import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/places_repository.dart';
import 'places_event.dart';
import 'places_state.dart';

class PlacesBloc extends Bloc<PlacesEvent, PlacesState> {
  final PlacesRepository _repo = PlacesRepository();

  PlacesBloc() : super(PlacesInitial()) {
    on<FetchPlaces>(_onFetch);
    on<ClearPlaces>(_onClear);
  }

  Future<void> _onFetch(FetchPlaces event, Emitter<PlacesState> emit) async {
    emit(PlacesLoading());
    try {
      final places = await _repo.fetchNearby(
        point: event.point,
        type: event.type,
      );
      emit(PlacesSuccess(places, event.type));
    } catch (e) {
      emit(PlacesFailure(e.toString()));
    }
  }

  void _onClear(ClearPlaces event, Emitter<PlacesState> emit) {
    emit(PlacesInitial());
  }
}