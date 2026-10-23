import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import '../services/isochrone_service.dart';
import '../repositories/routing_repository.dart';
import 'comparison_screen.dart';
import '../blocs/location/location_bloc.dart';
import '../blocs/location/location_state.dart';
import '../blocs/optimization/optimization_bloc.dart';
import '../blocs/optimization/optimization_event.dart';
import '../blocs/places/places_bloc.dart';
import '../blocs/places/places_event.dart';
import '../blocs/places/places_state.dart';
import '../models/nearby_place.dart';
import '../models/rendezvous_point.dart';
import '../models/user_location.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class ResultScreen extends StatelessWidget {
  final RendezvousPoint result;

  const ResultScreen({super.key, required this.result});

  void _shareMeetingPoint(BuildContext context) {
    final lat = result.position.latitude.toStringAsFixed(6);
    final lng = result.position.longitude.toStringAsFixed(6);
    final mapsLink = 'https://www.google.com/maps?q=$lat,$lng';

    final message = '''
📍 Fair Meeting Point Found!

Fairness Score: ${result.fairnessScore.toStringAsFixed(1)}%
Mean Travel Time: ${result.meanMinutes.toStringAsFixed(1)} min
Max Travel Time: ${result.maxMinutes.toStringAsFixed(1)} min

$mapsLink
''';
    Share.share(message);
  }
  Future<void> _runComparison(BuildContext context, List<UserLocation> users) async {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Expanded(
            child: Text(
              'Running Isochrone method...\nThis may take 20-40 seconds\n(Screen will stay on)',
            ),
          ),
        ],
      ),
    ),
  );

  try {
    await WakelockPlus.enable(); // Keep device awake

    final isochroneService = IsochroneService(RoutingRepository());

    final sw = Stopwatch()..start();
    final isochroneResult = await isochroneService.optimize(users: users);
    sw.stop();
    final isochroneTime = sw.elapsed;

    final weiszfeldTime = result.computationTime ?? const Duration(seconds: 12);

    if (context.mounted) {
      Navigator.pop(context); // close loading dialog

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ComparisonScreen(
            weiszfeldResult: result,
            isochroneResult: isochroneResult,
            users: users,
            weiszfeldTime: weiszfeldTime,
            isochroneTime: isochroneTime,
          ),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Comparison failed: $e')),
      );
    }
  } finally {
    await WakelockPlus.disable(); // Always release
  }
}

  @override
  Widget build(BuildContext context) {
    final locationState = context.watch<LocationBloc>().state;
    final users = locationState.users;

    if (users.isEmpty) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Research Results'),
          backgroundColor: Colors.deepPurple,
          foregroundColor: Colors.white,
        ),
        body: const Center(
          child: Text('No participants found. Please go back and add people.'),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        title: const Text('Research Results'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: 'Share meeting point',
            onPressed: () => _shareMeetingPoint(context),
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
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _MapSection(result: result, users: users),
          const SizedBox(height: 16),
          _ResearchMetricsCard(result: result),
          const SizedBox(height: 12),
          _FairnessComparisonCard(result: result),
          const SizedBox(height: 12),
          _HybridScoreCard(result: result),

          const SizedBox(height: 12),

          // Compare button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _runComparison(context, users),
                icon: const Icon(Icons.compare_arrows),
                label: const Text('Compare with Isochrone Method'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),
          _TravelTimesSection(result: result, users: users),
          const SizedBox(height: 12),
          _PlacesSection(result: result),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// MAP SECTION
// ─────────────────────────────────────────────────────────────

class _MapSection extends StatelessWidget {
  final RendezvousPoint result;
  final List<UserLocation> users;

  const _MapSection({required this.result, required this.users});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: FlutterMap(
        options: MapOptions(
          initialCenter: result.position,
          initialZoom: 12.5,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.rendezvous_app',
          ),
          MarkerLayer(
            markers: users.map((user) {
              return Marker(
                point: user.position,
                width: 36,
                height: 36,
                child: Icon(Icons.location_pin, color: user.color, size: 36),
              );
            }).toList(),
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: result.centroid,
                width: 32,
                height: 32,
                child: const Icon(Icons.radio_button_checked,
                    color: Colors.grey, size: 28),
              ),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: result.position,
                width: 52,
                height: 52,
                child: const Icon(Icons.stars_rounded,
                    color: Colors.amber, size: 48),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// RESEARCH METRICS CARD
// ─────────────────────────────────────────────────────────────

class _ResearchMetricsCard extends StatelessWidget {
  final RendezvousPoint result;

  const _ResearchMetricsCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Research Metrics',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Weiszfeld method • ${result.iterations} iterations',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _MetricBox(
                    label: 'Total',
                    value: '${result.totalMinutes.toStringAsFixed(1)} min',
                    color: Colors.indigo,
                  ),
                  const SizedBox(width: 10),
                  _MetricBox(
                    label: 'Mean',
                    value: '${result.meanMinutes.toStringAsFixed(1)} min',
                    color: Colors.blue,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _MetricBox(
                    label: 'Max',
                    value: '${result.maxMinutes.toStringAsFixed(1)} min',
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 10),
                  _MetricBox(
                    label: 'Std Dev',
                    value: '${result.stdDevMinutes.toStringAsFixed(1)} min',
                    color: Colors.teal,
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

class _MetricBox extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MetricBox({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color.withOpacity(0.9),
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// FAIRNESS COMPARISON CARD
// ─────────────────────────────────────────────────────────────

class _FairnessComparisonCard extends StatelessWidget {
  final RendezvousPoint result;

  const _FairnessComparisonCard({required this.result});

  Color _scoreColor(double score) {
    if (score >= 85) return Colors.green;
    if (score >= 65) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final optColor = _scoreColor(result.fairnessScore);
    final cenColor = _scoreColor(result.centroidFairnessScore);
    final improvement = result.improvementInFairness;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Fairness Comparison',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Higher score = more equal travel times',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 20),
              _ScoreRow(
                icon: Icons.stars_rounded,
                iconColor: Colors.amber,
                title: 'Optimized Point (Weiszfeld)',
                score: result.fairnessScore,
                color: optColor,
              ),
              const SizedBox(height: 14),
              _ScoreRow(
                icon: Icons.radio_button_checked,
                iconColor: Colors.grey,
                title: 'Geographic Centroid',
                score: result.centroidFairnessScore,
                color: cenColor,
              ),
              if (improvement > 0) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                      Expanded(
                        child: Text(
                          '+${improvement.toStringAsFixed(1)} points fairer than simple midpoint',
                          style: const TextStyle(
                            fontSize: 13,
                            color: Colors.green,
                            fontWeight: FontWeight.w600,
                          ),
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

class _ScoreRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final double score;
  final Color color;

  const _ScoreRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.score,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 14)),
            ),
            Text(
              '${score.toStringAsFixed(1)}%',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: score / 100,
            minHeight: 8,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────
// HYBRID SCORE CARD
// ─────────────────────────────────────────────────────────────

class _HybridScoreCard extends StatelessWidget {
  final RendezvousPoint result;

  const _HybridScoreCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Hybrid Score (α = 0.6)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Balances efficiency (mean time) and fairness (std. deviation)\nLower score is better',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    result.hybridScore.toStringAsFixed(3),
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.deepPurple,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Combined efficiency + fairness metric\nas defined in the research paper',
                      style: TextStyle(fontSize: 13),
                    ),
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

// ─────────────────────────────────────────────────────────────
// TRAVEL TIMES SECTION
// ─────────────────────────────────────────────────────────────

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
    final maxTime = result.travelTimes.isEmpty
        ? 0.0
        : result.travelTimes.reduce((a, b) => a > b ? a : b);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Travel Times to Meeting Point',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ...List.generate(users.length, (i) {
                final mins = result.travelMinutes(i);
                final isLongest =
                    result.travelTimes[i] == maxTime && users.length > 1;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Row(
                    children: [
                      Icon(Icons.person_pin_circle,
                          color: users[i].color, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Person ${i + 1}',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Icon(_modeIcon(users[i].travelMode),
                                    size: 13, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(
                                  _modeName(users[i].travelMode),
                                  style: const TextStyle(
                                      fontSize: 12, color: Colors.grey),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (isLongest)
                        Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: const Text(
                            'longest',
                            style:
                                TextStyle(fontSize: 10, color: Colors.orange),
                          ),
                        ),
                      Text(
                        '${mins.toStringAsFixed(1)} min',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────
// PLACES SECTION
// ─────────────────────────────────────────────────────────────

class _PlacesSection extends StatelessWidget {
  final RendezvousPoint result;

  const _PlacesSection({required this.result});

  void _sharePlace(NearbyPlace place) {
    final mapsLink =
        'https://www.google.com/maps?q=${place.lat},${place.lng}';
    Share.share('${place.name}\n${place.distanceText}\n$mapsLink');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Nearby Places',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _PlaceChip(
                    label: 'Cafes',
                    onTap: () => context
                        .read<PlacesBloc>()
                        .add(FetchPlaces(result.position, 'cafe')),
                  ),
                  const SizedBox(width: 8),
                  _PlaceChip(
                    label: 'Restaurants',
                    onTap: () => context
                        .read<PlacesBloc>()
                        .add(FetchPlaces(result.position, 'restaurant')),
                  ),
                  const SizedBox(width: 8),
                  _PlaceChip(
                    label: 'Parks',
                    onTap: () => context
                        .read<PlacesBloc>()
                        .add(FetchPlaces(result.position, 'park')),
                  ),
                ],
              ),
              const SizedBox(height: 16),
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

class _PlaceChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PlaceChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: onTap,
      backgroundColor: Colors.deepPurple.shade50,
      side: BorderSide(color: Colors.deepPurple.shade200),
    );
  }
}