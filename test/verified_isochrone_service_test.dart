import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rendezvous_app/models/research_venue.dart';
import 'package:rendezvous_app/services/directions_verification_service.dart';
import 'package:rendezvous_app/services/venue_routing_service.dart';
import 'package:rendezvous_app/services/venue_selection_service.dart';
import 'package:rendezvous_app/services/verified_isochrone_service.dart';
import 'group_isochrone_optimizer_test.dart' show people, config, response;
import 'directions_verification_service_test.dart' show fixture;

void main() {
  test(
    'Continues past empty venue overlap and verifies inbound routes',
    () async {
      final client = MockClient((request) async {
        expect(request.headers.containsKey('authorization'), false);
        final body = jsonDecode(request.body);
        if (request.url.path.contains('/matrix/')) {
          return http.Response('{"durations":[[9],[10]]}', 200);
        }
        if (request.url.path.contains('/isochrones/')) {
          final p = body['locations'][0];
          return http.Response(
            jsonEncode(response(p[0], p[1], body['range'][0].toDouble())),
            200,
          );
        }
        return http.Response(
          jsonEncode(fixture(body['coordinates'], seconds: 10)),
          200,
        );
      });
      addTearDown(client.close);
      final result = await VerifiedIsochroneService(client).evaluate(
        users: people(2, spacing: .002),
        venues: [
          ResearchVenue(
            id: '1',
            name: 'Fixture',
            category: 'cafe',
            longitude: 77.004,
            latitude: 12,
          ),
        ],
        policy: VenueEligibilityPolicy(
          id: 'public',
          categories: {'cafe'},
          includeBoundary: true,
        ),
        searchConfig: config(),
        matrixConfig: const VenueRoutingConfig(maxRequests: 2),
        directionsConfig: const DirectionsConfig(maxVenues: 1, maxRequests: 2),
      );
      expect(
        result.search!.evaluations.any(
          (e) => !e.commonRegion.isEmpty && !e.feasible,
        ),
        true,
      );
      expect(result.search!.selectedThresholdSeconds, inInclusiveRange(10, 11));
      expect(
        result.directions!.venues.single.directionsThresholdVerified,
        true,
      );
    },
  );
}
