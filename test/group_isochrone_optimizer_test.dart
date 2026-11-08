import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/group_isochrone_search.dart';
import 'package:rendezvous_app/models/road_network_isochrone.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/repositories/isochrone_repository.dart';
import 'package:rendezvous_app/services/group_isochrone_optimizer.dart';
import 'package:rendezvous_app/services/isochrone_intersection_service.dart';

List<UserLocation> people(int n, {double spacing = .02}) => List.generate(
  n,
  (i) => UserLocation(
    id: '$i',
    position: LatLng(12, 77 + i * spacing),
    color: Colors.red,
    travelMode: TravelMode.walking,
  ),
);

GroupIsochroneSearchConfig config({
  int min = 2,
  int max = 20,
  int step = 2,
  int precision = 1,
  int requests = 200,
  int iterations = 32,
  int concurrency = 1,
}) => GroupIsochroneSearchConfig(
  minimumThreshold: Duration(seconds: min),
  maximumThreshold: Duration(seconds: max),
  initialStep: Duration(seconds: step),
  timePrecision: Duration(seconds: precision),
  maxRequests: requests,
  maxIterations: iterations,
  concurrency: concurrency,
);

List<List<double>> ring(double x, double y, double r) => [
  [x - r, y - r],
  [x + r, y - r],
  [x + r, y + r],
  [x - r, y + r],
  [x - r, y - r],
];
Map<String, dynamic> response(
  double x,
  double y,
  double seconds, {
  double? radius,
  double dx = 0,
}) => {
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'properties': {'group_index': 0, 'value': seconds},
      'geometry': {
        'type': 'Polygon',
        'coordinates': [ring(x + dx, y, radius ?? seconds / 1000)],
      },
    },
  ],
};

class Harness {
  final thresholds = <double>[];
  final paths = <String>[];
  final origins = <List<dynamic>>[];
  late final MockClient client;
  late final GroupIsochroneOptimizer optimizer;
  Harness({
    Map<String, dynamic> Function(double, double, double)? shape,
    int status = 200,
    String? rawBody,
  }) {
    client = MockClient((request) async {
      final body = jsonDecode(request.body);
      expect(request.method, 'POST');
      expect(body['range_type'], 'time');
      expect(body['location_type'], 'start');
      expect((body['locations'] as List).length, 1);
      final p = body['locations'][0] as List;
      final t = (body['range'][0] as num).toDouble();
      thresholds.add(t);
      paths.add(request.url.pathSegments.last);
      origins.add(p);
      return http.Response(
        rawBody ??
            jsonEncode(
              (shape ?? response)(
                (p[0] as num).toDouble(),
                (p[1] as num).toDouble(),
                t,
              ),
            ),
        status,
      );
    });
    optimizer = GroupIsochroneOptimizer(
      repository: IsochroneRepository(client: client),
    );
  }
}

void main() {
  for (final count in [2, 3, 5, 10, 20]) {
    test(
      '$count participants: initial feasible, actual ordered contours',
      () async {
        final h = Harness();
        addTearDown(h.client.close);
        final users = people(count, spacing: .01);
        final result = await h.optimizer.optimize(
          participants: users,
          config: config(min: 100, max: 100),
        );
        expect(result.status, GroupIsochroneStatus.feasibleRegion);
        expect(result.termination, GroupIsochroneTermination.minimumFeasible);
        expect(result.selectedThresholdSeconds, 100);
        expect(result.lastInfeasibleThreshold, isNull);
        expect(result.achievedBracketWidth, isNull);
        expect(result.apiCalls, count);
        expect(result.cacheHits, 0);
        expect(result.participantCount, count);
        expect(result.iterations, 1);
        expect(result.thresholdEvaluations, 1);
        expect(result.travelProfiles, List.filled(count, 'foot-walking'));
        expect(
          result.selectedIsochrones.map((i) => i.origin.longitude),
          users.map((u) => u.position.longitude),
        );
        expect(result.geometry!['type'], 'Polygon');
        expect(
          result.timing.total,
          result.timing.retrieval +
              result.timing.intersection +
              result.timing.searchOverhead,
        );
        expect(result.timing.searchOverhead >= Duration.zero, isTrue);
        expect(() => result.participants.clear(), throwsUnsupportedError);
      },
    );
  }

  test(
    'expands then refines the zero-area boundary to requested precision',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(),
      );
      // Each origin has a square of half-width tau/1000 degrees. Origins are .02
      // degrees apart: tau=10 touches at a line, tau>10 has positive common area.
      expect(r.evaluations.map((e) => e.thresholdSeconds), [
        2,
        4,
        8,
        16,
        12,
        10,
        11,
      ]);
      expect(r.evaluations.map((e) => e.feasible), [
        false,
        false,
        false,
        true,
        true,
        false,
        true,
      ]);
      expect(r.selectedThresholdSeconds, 11);
      expect(r.lastInfeasibleThreshold, const Duration(seconds: 10));
      expect(r.achievedBracketWidth, const Duration(seconds: 1));
      expect(r.termination, GroupIsochroneTermination.precisionReached);
      expect(r.apiCalls, 14);
      expect(r.iterations, 7);
      expect(r.thresholdEvaluations, 7);
      final region = r.geometry!['coordinates'][0] as List;
      expect(region.map((p) => p[0]).toSet(), {77.009, 77.011});
    },
  );

  test(
    'permanently disjoint: samples maximum exactly and reports no region found',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2, spacing: .2),
        config: config(max: 10),
      );
      expect(r.evaluations.map((e) => e.thresholdSeconds), [2, 4, 8, 10]);
      expect(r.status, GroupIsochroneStatus.noFeasibleRegionFound);
      expect(
        r.termination,
        GroupIsochroneTermination.maximumThresholdInfeasible,
      );
      expect(r.failure, isNull);
      expect(r.geometry, isNull);
      expect(r.selectedThreshold, isNull);
      expect(r.lastInfeasibleThreshold, const Duration(seconds: 10));
    },
  );

  test('min equals max: no redundant threshold request', () async {
    final h = Harness();
    addTearDown(h.client.close);
    final r = await h.optimizer.optimize(
      participants: people(2),
      config: config(min: 10, max: 10),
    );
    expect(r.status, GroupIsochroneStatus.noFeasibleRegionFound);
    expect(r.apiCalls, 2);
    expect(r.iterations, 1);
  });

  test(
    'mixed modes use each origin and the existing profile mapping',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final users = people(3);
      users[0] = users[0].copyWith(travelMode: TravelMode.driving);
      users[1] = users[1].copyWith(travelMode: TravelMode.cycling);
      final r = await h.optimizer.optimize(
        participants: users,
        config: config(min: 100, max: 100, concurrency: 2),
      );
      expect(r.travelProfiles, [
        'driving-car',
        'cycling-regular',
        'foot-walking',
      ]);
      expect(h.paths, ['driving-car', 'cycling-regular', 'foot-walking']);
      expect(h.origins, [
        [77, 12],
        [77.02, 12],
        [77.04, 12],
      ]);
      expect(
        r.selectedIsochrones.map((i) => i.travelMode),
        users.map((u) => u.travelMode),
      );
    },
  );

  test(
    'holes and disconnected components survive as actual common geometry',
    () async {
      final h = Harness(
        shape: (x, y, t) => {
          'type': 'FeatureCollection',
          'features': [
            {
              'type': 'Feature',
              'properties': {'group_index': 0, 'value': t},
              'geometry': {
                'type': 'MultiPolygon',
                'coordinates': [
                  [ring(77, 12, .02), ring(77, 12, .005).reversed.toList()],
                  [ring(77.05, 12, .01)],
                ],
              },
            },
          ],
        },
      );
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(min: 20, max: 20),
      );
      expect(r.status, GroupIsochroneStatus.feasibleRegion);
      expect(r.geometry!['type'], 'MultiPolygon');
      final polygons = r.geometry!['coordinates'] as List;
      expect(polygons.length, 2);
      expect(polygons.map((p) => (p as List).length).toList()..sort(), [1, 2]);
    },
  );

  test(
    'same origin/profile requests are cached without losing participant order',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final users = people(3, spacing: 0);
      users[2] = users[2].copyWith(travelMode: TravelMode.cycling);
      final r = await h.optimizer.optimize(
        participants: users,
        config: config(min: 20, max: 20, requests: 2),
      );
      expect(r.apiCalls, 2);
      expect(r.cacheHits, 1);
      expect(h.paths, ['foot-walking', 'cycling-regular']);
      expect(r.selectedIsochrones.length, 3);
      expect(
        identical(r.selectedIsochrones[0], r.selectedIsochrones[1]),
        isTrue,
      );
      final again = await h.optimizer.optimize(
        participants: users,
        config: config(min: 20, max: 20),
      );
      expect(again.apiCalls, 2);
      expect(h.paths.length, 4); // no cross-search cache
    },
  );

  test(
    'request key includes threshold, never reuses a smaller isochrone',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(3, spacing: 0),
        config: config(min: 2, max: 20),
      );
      expect(r.apiCalls, 1);
      expect(r.cacheHits, 2);
      final other = Harness();
      addTearDown(other.client.close);
      final expanded = await other.optimizer.optimize(
        participants: people(2),
        config: config(),
      );
      expect(expanded.apiCalls, 2 * expanded.thresholdEvaluations);
      expect(other.thresholds.toSet().length, expanded.thresholdEvaluations);
    },
  );

  for (final budget in [0, 1, 6, 8]) {
    test('strict request budget $budget; no partial threshold batch', () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(requests: budget),
      );
      expect(r.apiCalls <= budget, isTrue);
      expect(r.apiCalls, h.paths.length);
      expect(r.apiCalls % 2, 0);
      expect(r.termination, GroupIsochroneTermination.requestBudgetExhausted);
      if (budget == 8) {
        expect(r.status, GroupIsochroneStatus.feasibleRegion);
        expect(r.selectedThresholdSeconds, 16);
        expect(r.achievedBracketWidth, const Duration(seconds: 8));
      } else {
        expect(r.status, GroupIsochroneStatus.noFeasibleRegionFound);
      }
    });
  }

  for (final iterations in [0, 1, 4]) {
    test('iteration budget $iterations is hard-bounded', () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(iterations: iterations),
      );
      expect(r.iterations, iterations);
      expect(r.thresholdEvaluations, iterations);
      expect(r.termination, GroupIsochroneTermination.iterationBudgetExhausted);
      if (iterations == 4) expect(r.selectedThresholdSeconds, 16);
    });
  }

  test(
    'controlled workers cap concurrency, including 20 participants',
    () async {
      final repo = YieldingRepository();
      final r = await GroupIsochroneOptimizer(repository: repo).optimize(
        participants: people(20, spacing: .01),
        config: config(min: 100, max: 100, concurrency: 3),
      );
      expect(r.status, GroupIsochroneStatus.feasibleRegion);
      expect(repo.peak, 3);
      expect(repo.active, 0);
      expect(r.apiCalls, 20);
    },
  );

  test('out-of-order completion still returns participant order', () async {
    final repo = ControlledRepository();
    final users = people(3);
    final future = GroupIsochroneOptimizer(repository: repo).optimize(
      participants: users,
      config: config(min: 100, max: 100, concurrency: 3),
    );
    expect(repo.pending.length, 3);
    for (final i in [2, 0, 1]) {
      repo.complete(i);
    }
    final result = await future;
    expect(result.status, GroupIsochroneStatus.feasibleRegion);
    expect(
      result.selectedIsochrones.map((iso) => iso.origin.longitude),
      users.map((u) => u.position.longitude),
    );
  });

  test('failure stops new work and drains every in-flight call', () async {
    final repo = YieldingRepository(failFirst: true);
    final r = await GroupIsochroneOptimizer(repository: repo).optimize(
      participants: people(20, spacing: .01),
      config: config(min: 100, max: 100, concurrency: 3),
    );
    expect(r.status, GroupIsochroneStatus.failed);
    expect(r.failure!.category, GroupIsochroneFailureCategory.timeout);
    expect(r.apiCalls, 3);
    expect(repo.active, 0);
    expect(repo.started, 3);
    expect(r.thresholdEvaluations, 0);
  });

  for (final kind in [
    IsochroneFailure.requestFailed,
    IsochroneFailure.timeout,
    IsochroneFailure.emptyResult,
    IsochroneFailure.malformedResponse,
  ]) {
    test(
      'retrieval $kind is a failure, never successful empty overlap',
      () async {
        final cause = IsochroneException(
          kind,
          'fixture failure',
          statusCode: 503,
          providerCode: 3099,
          retryAfter: '60',
        );
        final r = await GroupIsochroneOptimizer(
          repository: FailingRepository(cause),
        ).optimize(participants: people(2), config: config());
        expect(r.status, GroupIsochroneStatus.failed);
        expect(r.termination, GroupIsochroneTermination.failure);
        expect(r.failure!.cause, same(cause));
        expect(r.failure!.httpStatusCode, 503);
        expect(r.failure!.providerErrorCode, 3099);
        expect(r.failure!.retryAfter, '60');
        expect(r.failure!.participantIndex, 0);
        expect(r.geometry, isNull);
        expect(r.selectedThreshold, isNull);
        expect(r.apiCalls, 1);
        expect(
          r.failure!.category,
          {
            IsochroneFailure.requestFailed:
                GroupIsochroneFailureCategory.providerFailure,
            IsochroneFailure.timeout: GroupIsochroneFailureCategory.timeout,
            IsochroneFailure.emptyResult:
                GroupIsochroneFailureCategory.retrievalEmpty,
            IsochroneFailure.malformedResponse:
                GroupIsochroneFailureCategory.malformedResponse,
          }[kind],
        );
      },
    );
  }

  for (final (caseIndex, h) in [
    Harness(status: 429, rawBody: '{"error":{"code":3004,"message":"quota"}}'),
    Harness(rawBody: 'not JSON'),
  ].indexed) {
    test(
      'real repository HTTP/malformed error propagates with no retries $caseIndex',
      () async {
        addTearDown(h.client.close);
        final r = await h.optimizer.optimize(
          participants: people(2),
          config: config(),
        );
        expect(r.status, GroupIsochroneStatus.failed);
        expect(r.apiCalls, 1);
        expect(r.geometry, isNull);
        expect(r.failure!.cause, isA<IsochroneException>());
      },
    );
  }

  test(
    'valid but nonnested expansion contours flag observed nonmonotonicity',
    () async {
      final h = Harness(
        shape: (x, y, t) => response(x, y, t, dx: t == 4 ? 0.02 : 0),
      );
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(),
      );
      expect(r.status, GroupIsochroneStatus.failed);
      expect(
        r.failure!.category,
        GroupIsochroneFailureCategory.numericalNonmonotonicity,
      );
      expect(r.geometry, isNull);
      expect(r.thresholdEvaluations, 1);
    },
  );

  test(
    'nonnested binary contour clears previously feasible candidate',
    () async {
      final h = Harness(
        shape: (x, y, t) => response(x, y, t, radius: t == 12 ? 0.017 : null),
      );
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(),
      );
      expect(r.evaluations.any((e) => e.feasible), isTrue);
      expect(r.status, GroupIsochroneStatus.failed);
      expect(r.selectedThreshold, isNull);
      expect(r.geometry, isNull);
      expect(
        r.failure!.category,
        GroupIsochroneFailureCategory.numericalNonmonotonicity,
      );
    },
  );

  test(
    'invalid grid geometry fails explicitly, not as an empty region',
    () async {
      final h = Harness(shape: (x, y, t) => response(x, y, t, dx: .00000001));
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2),
        config: config(),
      );
      expect(r.status, GroupIsochroneStatus.failed);
      expect(
        r.failure!.category,
        GroupIsochroneFailureCategory.unsupportedGeometryPrecision,
      );
    },
  );

  test('self-intersecting geometry fails explicitly', () async {
    final h = Harness(
      shape: (x, y, t) => {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'group_index': 0, 'value': t},
            'geometry': {
              'type': 'Polygon',
              'coordinates': [
                [
                  [77, 12],
                  [77.01, 12.01],
                  [77, 12.01],
                  [77.01, 12],
                  [77, 12],
                ],
              ],
            },
          },
        ],
      },
    );
    addTearDown(h.client.close);
    final r = await h.optimizer.optimize(
      participants: people(2),
      config: config(),
    );
    expect(r.failure!.category, GroupIsochroneFailureCategory.invalidGeometry);
  });

  test('injected intersection dependency failures remain explicit', () async {
    final h = Harness();
    addTearDown(h.client.close);
    final r = await GroupIsochroneOptimizer(
      repository: IsochroneRepository(client: h.client),
      intersectionService: ThrowingIntersector(),
    ).optimize(participants: people(2), config: config());
    expect(r.status, GroupIsochroneStatus.failed);
    expect(r.failure!.cause, isA<IsochroneIntersectionException>());
  });

  test(
    'incorrect retrieved provenance is rejected before geometry use',
    () async {
      final r = await GroupIsochroneOptimizer(
        repository: YieldingRepository(wrongProvenance: true),
      ).optimize(participants: people(2), config: config(min: 100, max: 100));
      expect(
        r.failure!.category,
        GroupIsochroneFailureCategory.invalidDependencyResult,
      );
      expect(r.geometry, isNull);
    },
  );

  test(
    'fractional seconds and subsecond refinement keep units exact',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(2, spacing: .001),
        config: const GroupIsochroneSearchConfig(
          minimumThreshold: Duration(milliseconds: 500),
          maximumThreshold: Duration(milliseconds: 1500),
          initialStep: Duration(milliseconds: 500),
          timePrecision: Duration(milliseconds: 100),
        ),
      );
      expect(r.status, GroupIsochroneStatus.feasibleRegion);
      expect(r.selectedThresholdSeconds, .5625);
      expect(r.achievedBracketWidth, const Duration(microseconds: 62500));
      expect(r.evaluations.map((e) => e.thresholdSeconds), [
        .5,
        1,
        .75,
        .625,
        .5625,
      ]);
    },
  );

  test('expansion clamps to maximum with an oversized initial step', () async {
    final h = Harness();
    addTearDown(h.client.close);
    final r = await h.optimizer.optimize(
      participants: people(2, spacing: .2),
      config: config(max: 5, step: 100),
    );
    expect(r.evaluations.map((e) => e.thresholdSeconds), [2, 5]);
    expect(h.thresholds.every((t) => t <= 5), isTrue);
  });

  test(
    'actual repository timeout is distinct from empty intersection',
    () async {
      final client = MockClient((_) => Completer<http.Response>().future);
      addTearDown(client.close);
      final r = await GroupIsochroneOptimizer(
        repository: IsochroneRepository(
          client: client,
          timeout: const Duration(milliseconds: 1),
        ),
      ).optimize(participants: people(2), config: config());
      expect(r.status, GroupIsochroneStatus.failed);
      expect(r.failure!.category, GroupIsochroneFailureCategory.timeout);
      expect(r.apiCalls, 1);
      expect(r.geometry, isNull);
    },
  );

  test(
    'injected intersection output must retain group participant count',
    () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await GroupIsochroneOptimizer(
        repository: IsochroneRepository(client: h.client),
        intersectionService: WrongCountIntersector(),
      ).optimize(participants: people(3), config: config(min: 100, max: 100));
      expect(
        r.failure!.category,
        GroupIsochroneFailureCategory.invalidDependencyResult,
      );
      expect(r.geometry, isNull);
    },
  );

  test('invalid origin is rejected before HTTP requests', () async {
    final h = Harness();
    addTearDown(h.client.close);
    final users = people(2);
    users[0] = users[0].copyWith(position: NonfiniteOrigin());
    final r = await h.optimizer.optimize(participants: users, config: config());
    expect(r.failure!.category, GroupIsochroneFailureCategory.invalidInput);
    expect(r.apiCalls, 0);
  });

  test('unsupported mode is rejected before any request', () async {
    final h = Harness();
    addTearDown(h.client.close);
    final users = people(2);
    users[1] = users[1].copyWith(travelMode: TravelMode.twoWheeler);
    final r = await h.optimizer.optimize(participants: users, config: config());
    expect(r.failure!.category, GroupIsochroneFailureCategory.unsupportedMode);
    expect(r.apiCalls, 0);
  });

  for (final n in [0, 1, 21]) {
    test('invalid participant count $n', () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(
        participants: people(n),
        config: config(),
      );
      expect(r.failure!.category, GroupIsochroneFailureCategory.invalidInput);
      expect(r.apiCalls, 0);
    });
  }
  for (final (caseIndex, c) in [
    config(min: 0),
    config(min: 20, max: 2),
    config(step: 0),
    config(precision: 0),
    config(requests: -1),
    config(iterations: -1),
    config(concurrency: 0),
    config(concurrency: 21),
  ].indexed) {
    test('rejects invalid configuration $caseIndex', () async {
      final h = Harness();
      addTearDown(h.client.close);
      final r = await h.optimizer.optimize(participants: people(2), config: c);
      expect(r.failure!.category, GroupIsochroneFailureCategory.invalidInput);
      expect(r.apiCalls, 0);
    });
  }
}

class FailingRepository extends IsochroneRepository {
  final IsochroneException error;
  FailingRepository(this.error);
  @override
  Future<RoadNetworkIsochrone> getIsochrone({
    required LatLng origin,
    required TravelMode travelMode,
    required Duration travelTime,
  }) async => throw error;
}

class YieldingRepository extends IsochroneRepository {
  final bool failFirst, wrongProvenance;
  int active = 0, peak = 0, started = 0;
  YieldingRepository({this.failFirst = false, this.wrongProvenance = false});
  @override
  Future<RoadNetworkIsochrone> getIsochrone({
    required LatLng origin,
    required TravelMode travelMode,
    required Duration travelTime,
  }) async {
    final number = started++;
    active++;
    if (active > peak) peak = active;
    try {
      await Future<void>.value();
      if (failFirst && number == 0) {
        throw const IsochroneException(IsochroneFailure.timeout, 'fixture');
      }
      return RoadNetworkIsochrone(
        origin: origin,
        travelMode: travelMode,
        travelTime: wrongProvenance ? Duration.zero : travelTime,
        geoJson: response(
          origin.longitude,
          origin.latitude,
          travelTime.inSeconds.toDouble(),
        ),
      );
    } finally {
      active--;
    }
  }
}

class ThrowingIntersector extends IsochroneIntersectionService {
  @override
  IsochroneIntersectionResult intersect(
    List<RoadNetworkIsochrone> isochrones,
  ) => throw const IsochroneIntersectionException(
    IntersectionFailure.computationFailed,
    'fixture',
  );
}

class WrongCountIntersector extends IsochroneIntersectionService {
  @override
  IsochroneIntersectionResult intersect(
    List<RoadNetworkIsochrone> isochrones,
  ) => super.intersect(isochrones.take(2).toList());
}

class NonfiniteOrigin extends LatLng {
  NonfiniteOrigin() : super(0, 0);
  @override
  double get latitude => double.nan;
}

class ControlledRepository extends IsochroneRepository {
  final pending =
      <(LatLng, TravelMode, Duration, Completer<RoadNetworkIsochrone>)>[];
  @override
  Future<RoadNetworkIsochrone> getIsochrone({
    required LatLng origin,
    required TravelMode travelMode,
    required Duration travelTime,
  }) {
    final completer = Completer<RoadNetworkIsochrone>();
    pending.add((origin, travelMode, travelTime, completer));
    return completer.future;
  }

  void complete(int i) {
    final (origin, mode, time, completer) = pending[i];
    completer.complete(
      RoadNetworkIsochrone(
        origin: origin,
        travelMode: mode,
        travelTime: time,
        geoJson: response(
          origin.longitude,
          origin.latitude,
          time.inMicroseconds / Duration.microsecondsPerSecond,
        ),
      ),
    );
  }
}
