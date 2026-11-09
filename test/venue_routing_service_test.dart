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
  for (var i = 0; i < 3; i++)
    ResearchVenue(
      id: 'v$i',
      name: 'Fixture',
      category: 'cafe',
      longitude: 78 + i * .01,
      latitude: 13,
    ),
];
void main() {
  for (final n in [3, 5, 10, 20]) {
    test(
      '$n mixed participants, asymmetric subsets, batching and order',
      () async {
        final client = MockClient((r) async {
          expect(r.url.host, 'api.heigit.org');
          expect(r.method, 'POST');
          final b = jsonDecode(r.body);
          final loc = b['locations'] as List;
          final src = b['sources'] as List;
          final dst = b['destinations'] as List;
          expect(loc.length <= 5, true);
          expect(src.length * dst.length <= 4, true);
          expect(src.every((s) => (loc[int.parse(s)][1] as num) == 12), true);
          expect(dst.every((s) => (loc[int.parse(s)][1] as num) == 13), true);
          final expected = {
            'driving-car': 0,
            'cycling-regular': 1,
            'foot-walking': 2,
          }[r.url.pathSegments.last];
          for (final s in src) {
            final idx = (((loc[int.parse(s)][0] as num) - 77) * 1000).round();
            expect(idx % 3, expected);
          }
          return http.Response(
            jsonEncode({
              'durations': [
                for (final s in src)
                  [
                    for (final d in dst)
                      (((loc[int.parse(s)][0] as num) - 77) * 1000).round() *
                              10 +
                          (((loc[int.parse(d)][0] as num) - 78) * 100).round() +
                          1,
                  ],
              ],
            }),
            200,
          );
        });
        addTearDown(client.close);
        final result = await VenueRoutingService(client: client).evaluate(
          participants: users(n),
          venues: venues(),
          config: const VenueRoutingConfig(maxLocations: 5, maxPairs: 4),
        );
        expect(result.reachablePairs, n * 3);
        expect(result.venues.map((v) => v.venue.id), ['v0', 'v1', 'v2']);
        for (var j = 0; j < 3; j++) {
          expect(result.venues[j].pairs.map((p) => p.seconds), [
            for (var i = 0; i < n; i++) i * 10 + j + 1,
          ]);
        }
        expect(result.apiFailures, 0);
      },
    );
  }
  test('statistics and threshold violations, zero tolerance', () async {
    final client = MockClient(
      (_) async =>
          http.Response('{"durations":[[10,20],[20,30],[30,40]]}', 200),
    );
    addTearDown(client.close);
    final p = users(
      3,
    ).map((u) => u.copyWith(travelMode: TravelMode.walking)).toList();
    final r = await VenueRoutingService(client: client).evaluate(
      participants: p,
      venues: venues().take(2).toList(),
      thresholdSeconds: 30,
      config: const VenueRoutingConfig(thresholdToleranceSeconds: 0),
    );
    final v = r.venues.first;
    expect(v.total, 60);
    expect(v.mean, 20);
    expect(v.maximum, 30);
    expect(v.populationStandardDeviation, closeTo(8.164965809, 1e-8));
    expect(v.matrixThresholdVerified, true);
    expect(r.venues.last.matrixThresholdVerified, false);
  });
  for (final body in [
    '{"durations":[[null,null,null]]}',
    '{"durations":[[999999,1,2]]}',
    '{"durations":[]}',
    'not json',
    '{"durations":[[-1,1,2]]}',
  ]) {
    test('null or malformed $body', () async {
      final client = MockClient((_) async => http.Response(body, 200));
      addTearDown(client.close);
      final r = await VenueRoutingService(client: client).evaluate(
        participants: users(1),
        venues: venues(),
        thresholdSeconds: 100,
      );
      expect(r.venues.length, 3);
      expect(r.venues.first.total, isNull);
      expect(r.venues.first.matrixThresholdVerified, isNull);
      expect(
        r.venues.first.pairs.first.status,
        body.contains('null')
            ? PairStatus.unreachable
            : PairStatus.malformedResponse,
      );
    });
  }
  test(
    'budgets preserve every unevaluated pair and duplicate coordinates',
    () async {
      final client = MockClient(
        (_) async => http.Response('{"durations":[[0]]}', 200),
      );
      addTearDown(client.close);
      final p = List.filled(3, users(1).first);
      final r = await VenueRoutingService(client: client).evaluate(
        participants: p,
        venues: venues(),
        config: const VenueRoutingConfig(
          maxLocations: 2,
          maxPairs: 1,
          maxRequests: 2,
        ),
      );
      expect(r.actualMatrixRequests, 2);
      expect(r.reachablePairs, 2);
      expect(
        r.venues
            .expand((v) => v.pairs)
            .where((p) => p.status == PairStatus.budgetExceeded)
            .length,
        7,
      );
      expect(r.cacheHits, 0);
    },
  );
  for (final status in [429, 500]) {
    test('provider $status', () async {
      final c = MockClient(
        (_) async =>
            http.Response('{}', status, headers: {'retry-after': '60'}),
      );
      addTearDown(c.close);
      final r = await VenueRoutingService(
        client: c,
      ).evaluate(participants: users(1), venues: venues());
      expect(r.apiFailures, 1);
      expect(r.requests.single.httpStatus, status);
      expect(r.requests.single.retryAfter, '60');
      expect(r.venues.first.pairs.first.status, PairStatus.providerFailure);
    });
  }
  test('timeout explicit', () async {
    final c = MockClient((_) => Completer<http.Response>().future);
    addTearDown(c.close);
    final r = await VenueRoutingService(client: c).evaluate(
      participants: users(1),
      venues: venues(),
      config: const VenueRoutingConfig(timeout: Duration(milliseconds: 1)),
    );
    expect(r.venues.first.pairs.first.status, PairStatus.timeout);
  });
  test('unsupported mode and invalid venue do not call HTTP', () async {
    final c = MockClient((_) async {
      fail('unexpected HTTP');
    });
    addTearDown(c.close);
    final r = await VenueRoutingService(client: c).evaluate(
      participants: [
        users(1).first.copyWith(travelMode: TravelMode.twoWheeler),
      ],
      venues: [
        ...venues(),
        ResearchVenue(
          id: 'bad',
          name: 'bad',
          category: 'cafe',
          longitude: double.nan,
          latitude: 12,
        ),
      ],
    );
    expect(r.venues.first.pairs.first.status, PairStatus.unsupportedMode);
    expect(r.venues.last.pairs.first.status, PairStatus.invalidCoordinates);
    expect(r.actualMatrixRequests, 0);
  });
  test('invalid budget and duplicate IDs rejected before calls', () async {
    final c = MockClient((_) async {
      fail('unexpected HTTP');
    });
    addTearDown(c.close);
    final service = VenueRoutingService(client: c);
    for (final r in [
      await service.evaluate(
        participants: users(1),
        venues: venues(),
        config: const VenueRoutingConfig(maxPairs: 0),
      ),
      await service.evaluate(
        participants: users(1),
        venues: [venues().first, venues().first],
      ),
    ]) {
      expect(r.inputError, isNotNull);
      expect(r.actualMatrixRequests, 0);
    }
  });
  test('empty venues makes no calls', () async {
    final r = await VenueRoutingService().evaluate(
      participants: users(3),
      venues: [],
    );
    expect(r.venues, isEmpty);
    expect(r.actualMatrixRequests, 0);
  });
}
