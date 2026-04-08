import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'blocs/location/location_bloc.dart';
import 'blocs/location/location_event.dart';
import 'blocs/location/location_state.dart';
import 'blocs/optimization/optimization_bloc.dart';
import 'blocs/optimization/optimization_event.dart';
import 'blocs/optimization/optimization_state.dart';
import 'blocs/places/places_bloc.dart';
import 'screens/result_screen.dart';
import 'widgets/persons_bottom_sheet.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => LocationBloc()),
        BlocProvider(create: (_) => OptimizationBloc()),
        BlocProvider(create: (_) => PlacesBloc()),
      ],
      child: MaterialApp(
        title: 'Rendezvous',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const MapScreen(),
      ),
    );
  }
}

class MapScreen extends StatelessWidget {
  const MapScreen({super.key});

  void _openBottomSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: context.read<LocationBloc>()),
          BlocProvider.value(value: context.read<OptimizationBloc>()),
        ],
        child: const PersonsBottomSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<OptimizationBloc, OptimizationState>(
      listener: (context, state) {
        if (state is OptimizationSuccess) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MultiBlocProvider(
                providers: [
                  BlocProvider.value(value: context.read<LocationBloc>()),
                  BlocProvider.value(value: context.read<OptimizationBloc>()),
                  BlocProvider.value(value: context.read<PlacesBloc>()),
                ],
                child: ResultScreen(result: state.result),
              ),
            ),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rendezvous'),
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
          actions: [
            BlocBuilder<LocationBloc, LocationState>(
              builder: (context, state) {
                if (state.users.isEmpty) return const SizedBox.shrink();
                return IconButton(
                  icon: const Icon(Icons.clear_all),
                  onPressed: () =>
                      context.read<LocationBloc>().add(ClearAllLocations()),
                  tooltip: 'Clear all',
                );
              },
            ),
          ],
        ),
        body: BlocBuilder<LocationBloc, LocationState>(
          builder: (context, state) {
            return FlutterMap(
              options: MapOptions(
                initialCenter: const LatLng(12.9716, 77.5946),
                initialZoom: 12,
                onTap: (tapPosition, point) {
                  context
                      .read<LocationBloc>()
                      .add(AddUserLocation(point));
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.rendezvous_app',
                ),
                MarkerLayer(
                  markers: state.users.map((user) {
                    return Marker(
                      point: user.position,
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        onTap: () => context
                            .read<LocationBloc>()
                            .add(RemoveUserLocation(user.id)),
                        child: Icon(
                          Icons.location_pin,
                          color: user.color,
                          size: 40,
                        ),
                      ),
                    );
                  }).toList(),
                ),
                BlocBuilder<OptimizationBloc, OptimizationState>(
                  builder: (context, optState) {
                    if (optState is! OptimizationSuccess) {
                      return const SizedBox.shrink();
                    }
                    return MarkerLayer(
                      markers: [
                        Marker(
                          point: optState.result.position,
                          width: 60,
                          height: 60,
                          child: const Icon(
                            Icons.stars_rounded,
                            color: Colors.amber,
                            size: 50,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        ),

        // FAB to open people manager
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Optimization running indicator
            BlocBuilder<OptimizationBloc, OptimizationState>(
              builder: (context, state) {
                if (state is! OptimizationRunning) {
                  return const SizedBox.shrink();
                }
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Iteration ${state.iteration}...',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                      ),
                    ],
                  ),
                );
              },
            ),

            // People count badge + FAB
            BlocBuilder<LocationBloc, LocationState>(
              builder: (context, state) {
                return FloatingActionButton.extended(
                  onPressed: () => _openBottomSheet(context),
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.people),
                  label: Text(
                    state.users.isEmpty
                        ? 'Add People'
                        : '${state.users.length} People',
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}