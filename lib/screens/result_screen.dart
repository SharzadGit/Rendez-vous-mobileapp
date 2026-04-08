import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../blocs/location/location_bloc.dart';
import '../blocs/location/location_state.dart';
import '../blocs/optimization/optimization_bloc.dart';
import '../blocs/optimization/optimization_event.dart';
import '../models/rendezvous_point.dart';
import '../models/user_location.dart';
import '../blocs/places/places_bloc.dart';
import '../blocs/places/places_event.dart';
import '../blocs/places/places_state.dart';
import '../models/nearby_place.dart';
import 'package:share_plus/share_plus.dart';

class ResultScreen extends StatelessWidget {
  final RendezvousPoint result;

  const ResultScreen({super.key, required this.result});

  void _shareMeetingPoint(BuildContext context, RendezvousPoint result) {
    final lat = result.position.latitude.toStringAsFixed(6);
    final lng = result.position.longitude.toStringAsFixed(6);
    final mapsLink = 'https://www.google.com/maps?q=$lat,$lng';
    final fairness = result.fairnessScore.toStringAsFixed(1);
    final message = '📍 Meet here! (Fairness score: $fairness%)\n$mapsLink';
    Share.share(message);
  }

  @override
  Widget build(BuildContext context) {
    final users = context.read<LocationBloc>().state.users;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Rendezvous Point'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share meeting point',
            onPressed: () => _shareMeetingPoint(context, result),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Start over',
            onPressed: () {
              context.read<OptimizationBloc>().add(ResetOptimization());
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: ListView(
        children: [
          // Map showing all pins + result
          _MapSection(result: result, users: users),

          const SizedBox(height: 12),

          // Fairness score comparison
          _FairnessSection(result: result),

          const SizedBox(height: 12),

          // Per-person travel times
          _TravelTimesSection(result: result, users: users),

          const SizedBox(height: 12),
          
          // Nearby Places
          _PlacesSection(result: result),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ── MAP ──────────────────────────────────────────────────────────────────────

class _MapSection extends StatelessWidget {
  final RendezvousPoint result;
  final List<UserLocation> users;

  const _MapSection({required this.result, required this.users});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 280,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: result.position,
          initialZoom: 12,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.rendezvous_app',
          ),
          // User pins
          MarkerLayer(
            markers: users.map((user) {
              return Marker(
                point: user.position,
                width: 36,
                height: 36,
                child: Icon(
                  Icons.location_pin,
                  color: user.color,
                  size: 36,
                ),
              );
            }).toList(),
          ),
          // Centroid pin (for comparison)
          MarkerLayer(
            markers: [
              Marker(
                point: result.centroid,
                width: 36,
                height: 36,
                child: const Icon(
                  Icons.radio_button_checked,
                  color: Colors.grey,
                  size: 30,
                ),
              ),
            ],
          ),
          // Optimal point
          MarkerLayer(
            markers: [
              Marker(
                point: result.position,
                width: 56,
                height: 56,
                child: const Icon(
                  Icons.stars_rounded,
                  color: Colors.amber,
                  size: 50,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── FAIRNESS ─────────────────────────────────────────────────────────────────

class _FairnessSection extends StatelessWidget {
  final RendezvousPoint result;

  const _FairnessSection({required this.result});

  Color _scoreColor(double score) {
    if (score >= 85) return Colors.green;
    if (score >= 65) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final optimizedColor = _scoreColor(result.fairnessScore);
    final centroidColor = _scoreColor(result.centroidFairnessScore);
    final improvement = result.fairnessScore - result.centroidFairnessScore;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fairness Score',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Higher = more equal travel times for everyone',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 20),

              // Optimized score
              Row(
                children: [
                  const Icon(Icons.stars_rounded, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  const Text('Optimized Point',
                      style: TextStyle(fontSize: 14)),
                  const Spacer(),
                  Text(
                    '${result.fairnessScore.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: optimizedColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: result.fairnessScore / 100,
                  minHeight: 10,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(optimizedColor),
                ),
              ),

              const SizedBox(height: 16),

              // Centroid score
              Row(
                children: [
                  const Icon(Icons.radio_button_checked,
                      color: Colors.grey, size: 20),
                  const SizedBox(width: 8),
                  const Text('Geographic Midpoint',
                      style: TextStyle(fontSize: 14, color: Colors.grey)),
                  const Spacer(),
                  Text(
                    '${result.centroidFairnessScore.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: centroidColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: result.centroidFairnessScore / 100,
                  minHeight: 10,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation(centroidColor),
                ),
              ),

              // Improvement callout
              if (improvement > 0) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.shade200),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.trending_up,
                          color: Colors.green, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        '+${improvement.toStringAsFixed(1)} points fairer than simple midpoint',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── TRAVEL TIMES ─────────────────────────────────────────────────────────────

class _TravelTimesSection extends StatelessWidget {
  final RendezvousPoint result;
  final List<UserLocation> users;

  const _TravelTimesSection({required this.result, required this.users});

  IconData _modeIcon(TravelMode mode) {
    switch (mode) {
      case TravelMode.driving:
        return Icons.directions_car;
      case TravelMode.twoWheeler:
        return Icons.two_wheeler;
      case TravelMode.walking:
        return Icons.directions_walk;
    }
  }

  String _modeName(TravelMode mode) {
    switch (mode) {
      case TravelMode.driving:
        return 'Driving';
      case TravelMode.twoWheeler:
        return 'Two-Wheeler';
      case TravelMode.walking:
        return 'Walking';
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxTime = result.travelTimes.reduce((a, b) => a > b ? a : b);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Travel Times to Meeting Point',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ...List.generate(users.length, (i) {
                final mins = result.travelMinutes(i);
                final isLongest =
                    result.travelTimes[i] == maxTime && users.length > 1;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person_pin_circle,
                              color: users[i].color, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Person ${i + 1}',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 6),
                          Icon(_modeIcon(users[i].travelMode),
                              size: 14, color: Colors.grey),
                          const SizedBox(width: 2),
                          Text(
                            _modeName(users[i].travelMode),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                          const Spacer(),
                          if (isLongest)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(4),
                                border:
                                    Border.all(color: Colors.orange.shade200),
                              ),
                              child: const Text(
                                'longest',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.orange),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Text(
                            '${mins.toStringAsFixed(1)} min',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: users[i].color,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maxTime > 0
                              ? result.travelTimes[i] / maxTime
                              : 0,
                          minHeight: 8,
                          backgroundColor: Colors.grey.shade200,
                          valueColor:
                              AlwaysStoppedAnimation(users[i].color),
                        ),
                      ),
                    ],
                  ),
                );
              }),
              // Iterations info
              const Divider(),
              Row(
                children: [
                  const Icon(Icons.loop, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    'Converged in ${result.iterations} iterations',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── PLACES ───────────────────────────────────────────────────────────────────

class _PlacesSection extends StatelessWidget {
  final RendezvousPoint result;

  const _PlacesSection({required this.result});

  static const _types = [
    {'key': 'cafe', 'label': 'Cafés', 'icon': Icons.coffee},
    {'key': 'restaurant', 'label': 'Restaurants', 'icon': Icons.restaurant},
    {'key': 'park', 'label': 'Parks', 'icon': Icons.park},
  ];

  void _sharePlace(NearbyPlace place) {
    final lat = place.lat.toStringAsFixed(6);
    final lng = place.lng.toStringAsFixed(6);
    final name = Uri.encodeComponent(place.name);
    final mapsLink = 'https://www.google.com/maps/search/$name/@$lat,$lng,17z';
    final message = '📍 Let\'s meet at ${place.name}!\n$mapsLink';
    Share.share(message);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nearby Places',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              const Text(
                'Find somewhere to meet near the optimal point',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 16),

              // Type filter buttons
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _types.map((t) {
                  return BlocBuilder<PlacesBloc, PlacesState>(
                    builder: (context, state) {
                      final isActive = state is PlacesSuccess &&
                          state.type == t['key'];
                      return FilledButton.icon(
                        onPressed: () {
                          context.read<PlacesBloc>().add(
                                FetchPlaces(result.position,
                                    t['key'] as String),
                              );
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: isActive
                              ? Colors.deepPurple
                              : Colors.grey.shade200,
                          foregroundColor:
                              isActive ? Colors.white : Colors.black87,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                        icon: Icon(t['icon'] as IconData, size: 16),
                        label: Text(t['label'] as String,
                            style: const TextStyle(fontSize: 13)),
                      );
                    },
                  );
                }).toList(),
              ),

              const SizedBox(height: 16),

              // Results
              BlocBuilder<PlacesBloc, PlacesState>(
                builder: (context, state) {
                  if (state is PlacesLoading) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  if (state is PlacesFailure) {
                    return Text('Error: ${state.message}',
                        style: const TextStyle(color: Colors.red));
                  }
                  if (state is PlacesSuccess) {
                    if (state.places.isEmpty) {
                      return const Text(
                        'No places found nearby. Try a different type.',
                        style: TextStyle(color: Colors.grey),
                      );
                    }
                    return Column(
                      children: state.places.map((place) {
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            backgroundColor: Colors.deepPurple.shade50,
                            child: const Icon(Icons.place,
                                color: Colors.deepPurple, size: 18),
                          ),
                          title: Text(place.name,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(place.distanceText,
                              style: const TextStyle(fontSize: 12)),
                          dense: true,
                          trailing: IconButton(
                            icon: const Icon(Icons.share,
                                size: 18, color: Colors.deepPurple),
                            onPressed: () => _sharePlace(place),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        );
                      }).toList(),
                    );
                  }
                  return const Text(
                    'Tap a category above to find nearby places.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}