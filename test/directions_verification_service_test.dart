import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/models/research_venue.dart';
import 'package:rendezvous_app/services/venue_routing_service.dart';
import 'package:rendezvous_app/services/directions_verification_service.dart';

List<UserLocation> users(int n) => List.generate(
  n,
  (i) => UserLocation(
    id: 'p$i',
    position: LatLng(12, 77 + i * .001),
    color: Colors.red,
    travelMode: TravelMode.supported[i % 3],
  ),
);
List<ResearchVenue> venues() => [
  for (var i = 0; i < 2; i++)
    ResearchVenue(
      id: 'v$i',
      name: 'Fixture',
      category: 'cafe',
      longitude: 78 + i * .01,
      latitude: 13,
    ),
];
Map<String, dynamic> fixture(dynamic coordinates, {num seconds = 60}) => {
  'type': 'FeatureCollection',
  'metadata': {'source': 'offline fixture'},
  'features': [
    {
      'type': 'Feature',
      'geometry': {'type': 'LineString', 'coordinates': coordinates},
      'properties': {
        'summary': {'duration': seconds, 'distance': 1000},
        'way_points': [0, 1],
      },
    },
  ],
};
void main() {
  for (final n in [3, 5, 10, 20]) {
    test(
      '$n mixed participants, two shortlisted venues, direction and order',
      () async {
        var calls = 0;
        final c = MockClient((r) async {
          final j = calls ~/ n, i = calls % n;
          calls++;
          expect(r.method, 'POST');
          expect(
            r.url.toString(),
            'https://api.heigit.org/openrouteservice/v2/directions/${users(n)[i].travelMode.orsProfile}/geojson',
          );
          final body = jsonDecode(r.body);
          expect(body['coordinates'], [
            [77 + i * .001, 12],
            [78 + j * .01, 13],
          ]);
          expect(body['units'], 'm');
          return http.Response(
            jsonEncode(fixture(body['coordinates'], seconds: 10 + i + j)),
            200,
          );
        });
        addTearDown(c.close);
        final result = await DirectionsVerificationService(client: c).verify(
          participants: users(n),
          shortlist: venues(),
          thresholdSeconds: 100,
        );
        expect(result.actualRequests, 2 * n);
        expect(result.successfulRoutes, 2 * n);
        expect(result.failedRoutes, 0);
        expect(result.venues.map((v) => v.venue.id), ['v0', 'v1']);
        for (var j = 0; j < 2; j++) {
          expect(result.venues[j].routes.map((r) => r.seconds), [
            for (var i = 0; i < n; i++) 10 + i + j,
          ]);
          expect(result.venues[j].directionsThresholdVerified, true);
        }
        final route = result.venues.first.routes.first;
        expect(route.metres, 1000);
        expect(route.startSnapMetres, 0);
        expect(route.endSnapMetres, 0);
        expect(route.response!['metadata']['source'], 'offline fixture');
        expect(() => route.response!.clear(), throwsUnsupportedError);
      },
    );
  }
  test('haversine known distances, symmetry and antimeridian', () {
    expect(
      DirectionsVerificationService.endpointDistanceMetres(0, 0, 1, 0),
      closeTo(111195.0802, .001),
    );
    expect(
      DirectionsVerificationService.endpointDistanceMetres(1, 0, 0, 0),
      closeTo(111195.0802, .001),
    );
    expect(
      DirectionsVerificationService.endpointDistanceMetres(179.9, 0, -179.9, 0),
      closeTo(22239.016, .01),
    );
  });
  for (final snap in [false, true]) {
    test('threshold violation and excessive snapping $snap', () async {
      final c = MockClient((r) async {
        final coords = jsonDecode(r.body)['coordinates'];
        if (snap) coords[1][0] += 0.01;
        return http.Response(jsonEncode(fixture(coords)), 200);
      });
      addTearDown(c.close);
      final r = await DirectionsVerificationService(client: c).verify(
        participants: users(1),
        shortlist: venues(),
        thresholdSeconds: 30,
      );
      expect(
        r.venues.first.routes.first.status,
        snap
            ? DirectionsStatus.excessiveSnapping
            : DirectionsStatus.thresholdViolation,
      );
      expect(r.venues.first.directionsThresholdVerified, false);
      expect(r.venues.first.routes.first.seconds, 60);
      expect(r.venues.first.routes.first.thresholdSatisfied, false);
    });
  }
  test('matrix disagreement preserves both measurements', () async {
    final matrixClient = MockClient(
      (_) async => http.Response('{"durations":[[30,0]]}', 200),
    );
    addTearDown(matrixClient.close);
    final matrix = await VenueRoutingService(
      client: matrixClient,
    ).evaluate(participants: users(1), venues: venues());
    final c = MockClient(
      (r) async => http.Response(
        jsonEncode(fixture(jsonDecode(r.body)['coordinates'])),
        200,
      ),
    );
    addTearDown(c.close);
    final result = await DirectionsVerificationService(
      client: c,
    ).verify(participants: users(1), shortlist: venues(), matrix: matrix);
    final r = result.venues.first.routes.first;
    expect(r.matrixSeconds, 30);
    expect(r.seconds, 60);
    expect(r.absoluteDiscrepancySeconds, 30);
    expect(r.percentageDiscrepancy, 100);
    expect(result.venues.last.routes.first.percentageDiscrepancy, isNull);
    final bad = await DirectionsVerificationService(client: c).verify(
      participants: [users(1).first.copyWith(travelMode: TravelMode.walking)],
      shortlist: venues(),
      matrix: matrix,
    );
    expect(bad.inputError, isNotNull);
    expect(bad.actualRequests, 0);
  });
  for (final code in [2009, 2010, 2099]) {
    test('provider error $code', () async {
      final c = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {'code': code},
          }),
          404,
        ),
      );
      addTearDown(c.close);
      final r = await DirectionsVerificationService(
        client: c,
      ).verify(participants: users(1), shortlist: venues());
      expect(
        r.venues.first.routes.first.status,
        code == 2099
            ? DirectionsStatus.providerError
            : DirectionsStatus.unreachable,
      );
      expect(r.venues.first.routes.first.providerCode, code);
    });
  }
  test('429 stops scheduling and preserves Retry-After', () async {
    final c = MockClient(
      (_) async => http.Response('{}', 429, headers: {'retry-after': '60'}),
    );
    addTearDown(c.close);
    final r = await DirectionsVerificationService(
      client: c,
    ).verify(participants: users(3), shortlist: venues());
    expect(r.actualRequests, 1);
    expect(r.failedRoutes, 6);
    expect(
      r.routes.every(
        (r) => r.status == DirectionsStatus.rateLimited && r.retryAfter == '60',
      ),
      true,
    );
  });
  test('budget preserves all unrequested pairs', () async {
    final c = MockClient(
      (r) async => http.Response(
        jsonEncode(fixture(jsonDecode(r.body)['coordinates'])),
        200,
      ),
    );
    addTearDown(c.close);
    final r = await DirectionsVerificationService(client: c).verify(
      participants: users(3),
      shortlist: venues(),
      config: const DirectionsConfig(maxRequests: 2),
    );
    expect(r.actualRequests, 2);
    expect(r.successfulRoutes, 2);
    expect(
      r.routes
          .where((r) => r.status == DirectionsStatus.budgetExhausted)
          .length,
      4,
    );
  });
  test('timeouts', () async {
    final c = MockClient((_) => Completer<http.Response>().future);
    addTearDown(c.close);
    final r = await DirectionsVerificationService(client: c).verify(
      participants: users(1),
      shortlist: venues(),
      config: const DirectionsConfig(timeout: Duration(milliseconds: 1)),
    );
    expect(r.routes.every((r) => r.status == DirectionsStatus.timeout), true);
  });
  for (final data in [
    <String, dynamic>{},
    fixture([]),
    fixture([
      [77, 12],
    ]),
    fixture([
      [77, 12],
      [999, 12],
    ]),
    fixture([
      [77, 12],
      [78, 13],
    ], seconds: -1),
    {
      'type': 'FeatureCollection',
      'features': [
        {'type': 'Feature', 'properties': {}},
      ],
    },
  ]) {
    test('malformed ${jsonEncode(data)}', () async {
      final c = MockClient((_) async => http.Response(jsonEncode(data), 200));
      addTearDown(c.close);
      final r = await DirectionsVerificationService(
        client: c,
      ).verify(participants: users(1), shortlist: venues());
      expect(
        r.routes.every((r) => r.status == DirectionsStatus.malformedResponse),
        true,
      );
    });
  }
  test('empty routes explicitly unreachable', () async {
    final c = MockClient(
      (_) async =>
          http.Response('{"type":"FeatureCollection","features":[]}', 200),
    );
    addTearDown(c.close);
    final r = await DirectionsVerificationService(
      client: c,
    ).verify(participants: users(1), shortlist: venues());
    expect(r.routes.first.status, DirectionsStatus.unreachable);
  });
  test(
    'unsupported mode, invalid venue, oversized shortlist and empty list',
    () async {
      final c = MockClient((_) async {
        fail('unexpected request');
      });
      addTearDown(c.close);
      final s = DirectionsVerificationService(client: c);
      final unsupported = await s.verify(
        participants: [
          users(1).first.copyWith(travelMode: TravelMode.twoWheeler),
        ],
        shortlist: venues(),
      );
      expect(unsupported.routes.first.status, DirectionsStatus.unsupportedMode);
      final invalid = await s.verify(
        participants: users(1),
        shortlist: [
          ResearchVenue(
            id: 'bad',
            name: 'Fixture',
            category: 'cafe',
            longitude: double.nan,
            latitude: 12,
          ),
        ],
      );
      expect(invalid.routes.first.status, DirectionsStatus.invalidInput);
      final oversized = await s.verify(
        participants: users(1),
        shortlist: venues(),
        config: const DirectionsConfig(maxVenues: 1),
      );
      expect(oversized.inputError, isNotNull);
      expect(oversized.actualRequests, 0);
      final empty = await s.verify(participants: users(1), shortlist: []);
      expect(empty.actualRequests, 0);
      expect(empty.venues, isEmpty);
    },
  );
}
