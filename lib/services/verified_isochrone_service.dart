import 'package:http/http.dart' as http;
import '../models/group_isochrone_search.dart';
import '../models/research_venue.dart';
import '../models/user_location.dart';
import '../repositories/isochrone_repository.dart';
import 'directions_verification_service.dart';
import 'group_isochrone_optimizer.dart';
import 'venue_routing_service.dart';
import 'venue_selection_service.dart';

/// The transport must target a rate-limited proxy. The three stage budgets
/// cap total matrix, isochrone and final route requests independently.
class VerifiedIsochroneService {
  final http.Client client;
  VerifiedIsochroneService(this.client);

  Future<
    ({
      VenueRoutingResult matrix,
      GroupIsochroneSearchResult? search,
      DirectionsVerificationResult? directions,
    })
  >
  evaluate({
    required List<UserLocation> users,
    required List<ResearchVenue> venues,
    required VenueEligibilityPolicy policy,
    required GroupIsochroneSearchConfig searchConfig,
    required VenueRoutingConfig matrixConfig,
    required DirectionsConfig directionsConfig,
  }) async {
    final selector = VenueSelectionService();
    validateVenues(venues);
    final eligible = venues
        .where((v) => policy.categories.contains(v.category))
        .toList();
    final matrix = await VenueRoutingService(
      client: client,
    ).evaluate(participants: users, venues: eligible, config: matrixConfig);
    if (matrix.inputError != null ||
        matrix.venues.any(
          (v) => v.pairs.any(
            (p) =>
                p.status != PairStatus.success &&
                p.status != PairStatus.unreachable,
          ),
        )) {
      return (matrix: matrix, search: null, directions: null);
    }
    final ranked = matrix.venues.where((v) => v.fullyReachable).toList()
      ..sort((a, b) {
        final mean = a.mean!.compareTo(b.mean!);
        if (mean != 0) return mean;
        final worst = a.maximum!.compareTo(b.maximum!);
        return worst != 0 ? worst : a.venue.id.compareTo(b.venue.id);
      });
    if (ranked.isEmpty) return (matrix: matrix, search: null, directions: null);
    final shortlists = <Duration, List<ResearchVenue>>{};
    final search =
        await GroupIsochroneOptimizer(
          repository: IsochroneRepository(client: client),
        ).optimize(
          participants: users,
          config: searchConfig,
          acceptRegion: (region, threshold) {
            final seconds =
                threshold.inMicroseconds / Duration.microsecondsPerSecond;
            final selected = selector.select(
              region: region.geometry,
              candidates: [
                for (final v in ranked)
                  if (v.maximum! <= seconds) v.venue,
              ],
              policy: policy,
            );
            if (selected.error != null) throw FormatException(selected.error!);
            final ids = selected.venues.map((v) => v.id).toSet();
            shortlists[threshold] = [
              for (final v in ranked)
                if (ids.contains(v.venue.id)) v.venue,
            ];
            return ids.isNotEmpty;
          },
        );
    final threshold = search.selectedThreshold;
    if (threshold == null)
      return (matrix: matrix, search: search, directions: null);
    final directions = await DirectionsVerificationService(client: client)
        .verify(
          participants: users,
          shortlist: shortlists[threshold]!
              .take(directionsConfig.maxVenues)
              .toList(),
          matrix: matrix,
          thresholdSeconds: search.selectedThresholdSeconds,
          config: directionsConfig,
        );
    return (matrix: matrix, search: search, directions: directions);
  }
}
