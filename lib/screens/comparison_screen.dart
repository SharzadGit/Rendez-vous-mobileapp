import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import '../models/rendezvous_point.dart';
import '../models/user_location.dart';

class ComparisonScreen extends StatelessWidget {
  final RendezvousPoint weiszfeldResult;
  final RendezvousPoint isochroneResult;
  final List<UserLocation> users;
  final Duration weiszfeldTime;
  final Duration isochroneTime;

  const ComparisonScreen({
    super.key,
    required this.weiszfeldResult,
    required this.isochroneResult,
    required this.users,
    required this.weiszfeldTime,
    required this.isochroneTime,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F8),
      appBar: AppBar(
        title: const Text('Method Comparison'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Weiszfeld vs Isochrone',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Same participants • Same routing engine',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          const SizedBox(height: 20),

          // Fairness Score
          _ComparisonCard(
            title: 'Fairness Score',
            subtitle: 'Higher is better',
            weiszfeldValue: '${weiszfeldResult.fairnessScore.toStringAsFixed(1)}%',
            isochroneValue: '${isochroneResult.fairnessScore.toStringAsFixed(1)}%',
            weiszfeldBetter: weiszfeldResult.fairnessScore > isochroneResult.fairnessScore,
            isochroneBetter: isochroneResult.fairnessScore > weiszfeldResult.fairnessScore,
          ),

          const SizedBox(height: 12),

          // Max Travel Time
          _ComparisonCard(
            title: 'Max Travel Time',
            subtitle: 'Lower is better (fairness)',
            weiszfeldValue: '${weiszfeldResult.maxMinutes.toStringAsFixed(1)} min',
            isochroneValue: '${isochroneResult.maxMinutes.toStringAsFixed(1)} min',
            weiszfeldBetter: weiszfeldResult.maxTravelTime < isochroneResult.maxTravelTime,
            isochroneBetter: isochroneResult.maxTravelTime < weiszfeldResult.maxTravelTime,
          ),

          const SizedBox(height: 12),

          // Mean Travel Time
          _ComparisonCard(
            title: 'Mean Travel Time',
            subtitle: 'Lower is better (efficiency)',
            weiszfeldValue: '${weiszfeldResult.meanMinutes.toStringAsFixed(1)} min',
            isochroneValue: '${isochroneResult.meanMinutes.toStringAsFixed(1)} min',
            weiszfeldBetter: weiszfeldResult.meanTravelTime < isochroneResult.meanTravelTime,
            isochroneBetter: isochroneResult.meanTravelTime < weiszfeldResult.meanTravelTime,
          ),

          const SizedBox(height: 12),

          // Std Dev
          _ComparisonCard(
            title: 'Standard Deviation',
            subtitle: 'Lower is better (balance)',
            weiszfeldValue: '${weiszfeldResult.stdDevMinutes.toStringAsFixed(1)} min',
            isochroneValue: '${isochroneResult.stdDevMinutes.toStringAsFixed(1)} min',
            weiszfeldBetter: weiszfeldResult.stdDevTravelTime < isochroneResult.stdDevTravelTime,
            isochroneBetter: isochroneResult.stdDevTravelTime < weiszfeldResult.stdDevTravelTime,
          ),

          const SizedBox(height: 12),

          // Latency
          _ComparisonCard(
            title: 'Computation Time',
            subtitle: 'Lower is better (performance)',
            weiszfeldValue: '${weiszfeldTime.inSeconds}.${(weiszfeldTime.inMilliseconds % 1000) ~/ 100}s',
            isochroneValue: '${isochroneTime.inSeconds}.${(isochroneTime.inMilliseconds % 1000) ~/ 100}s',
            weiszfeldBetter: weiszfeldTime < isochroneTime,
            isochroneBetter: isochroneTime < weiszfeldTime,
          ),

          const SizedBox(height: 24),

          // Summary
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Summary',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Text(_generateSummary()),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _generateSummary() {
    final fairnessWinner = weiszfeldResult.fairnessScore > isochroneResult.fairnessScore
        ? 'Weiszfeld'
        : (isochroneResult.fairnessScore > weiszfeldResult.fairnessScore ? 'Isochrone' : 'Tie');

    final maxWinner = weiszfeldResult.maxTravelTime < isochroneResult.maxTravelTime
        ? 'Weiszfeld'
        : (isochroneResult.maxTravelTime < weiszfeldResult.maxTravelTime ? 'Isochrone' : 'Tie');

    final speedWinner = weiszfeldTime < isochroneTime ? 'Weiszfeld' : 'Isochrone';

    return 'Fairness winner: $fairnessWinner\n'
        'Best max travel time: $maxWinner\n'
        'Faster method: $speedWinner\n\n'
        'This matches the expected trade-off described in the research paper.';
  }
}

class _ComparisonCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String weiszfeldValue;
  final String isochroneValue;
  final bool weiszfeldBetter;
  final bool isochroneBetter;

  const _ComparisonCard({
    required this.title,
    required this.subtitle,
    required this.weiszfeldValue,
    required this.isochroneValue,
    required this.weiszfeldBetter,
    required this.isochroneBetter,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MethodValue(
                    label: 'Weiszfeld',
                    value: weiszfeldValue,
                    isWinner: weiszfeldBetter,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _MethodValue(
                    label: 'Isochrone',
                    value: isochroneValue,
                    isWinner: isochroneBetter,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodValue extends StatelessWidget {
  final String label;
  final String value;
  final bool isWinner;

  const _MethodValue({
    required this.label,
    required this.value,
    required this.isWinner,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: isWinner ? Colors.green.shade50 : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isWinner ? Colors.green.shade300 : Colors.grey.shade300,
        ),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: isWinner ? Colors.green.shade800 : Colors.grey.shade700,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isWinner ? Colors.green.shade800 : Colors.black87,
            ),
          ),
          if (isWinner) ...[
            const SizedBox(height: 4),
            const Text(
              'Better',
              style: TextStyle(fontSize: 11, color: Colors.green, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }
}