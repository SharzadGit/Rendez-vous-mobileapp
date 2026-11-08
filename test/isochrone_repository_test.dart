import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/repositories/isochrone_repository.dart';

const origin = LatLng(12.9716, 77.5946);
const threshold = Duration(seconds: 600);
const outer = [
  [77.5, 12.9],
  [77.7, 12.9],
  [77.7, 13.1],
  [77.5, 13.1],
  [77.5, 12.9],
];
const hole = [
  [77.55, 12.95],
  [77.55, 13.0],
  [77.6, 13.0],
  [77.6, 12.95],
  [77.55, 12.95],
];
const island = [
  [77.8, 12.9],
  [77.9, 12.9],
  [77.9, 13.0],
  [77.8, 12.9],
];

Map<String, dynamic> collection({
  String type = 'Polygon',
  dynamic coordinates,
  num value = 600,
}) => {
  'type': 'FeatureCollection',
  'bbox': [77.5, 12.9, 77.9, 13.1],
  'metadata': {
    'engine': {'version': 'fixture-only'},
  },
  'features': [
    <String, dynamic>{
      'type': 'Feature',
      'properties': <String, dynamic>{
        'group_index': 0,
        'value': value,
        'center': [77.5946, 12.9716],
      },
      'geometry': {
        'type': type,
        'coordinates': coordinates ?? [outer, hole],
      },
    },
  ],
};

TypeMatcher<IsochroneException> failure(IsochroneFailure kind) =>
    isA<IsochroneException>().having((e) => e.kind, 'kind', kind);

void main() {
  Future<dynamic> retrieve(dynamic body, {int status = 200}) async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode(body), status),
    );
    addTearDown(client.close);
    return IsochroneRepository(client: client).getIsochrone(
      origin: origin,
      travelMode: TravelMode.driving,
      travelTime: threshold,
    );
  }

  for (final entry in {
    TravelMode.driving: 'driving-car',
    TravelMode.cycling: 'cycling-regular',
    TravelMode.walking: 'foot-walking',
  }.entries) {
    test(
      'requests ${entry.value}, outgoing longitude/latitude and seconds',
      () async {
        var calls = 0;
        final fixture = collection(value: 1.5);
        final client = MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(
            request.url.toString(),
            'https://api.heigit.org/openrouteservice/v2/isochrones/${entry.value}',
          );
          expect(request.headers['Content-Type'], 'application/json');
          expect(request.headers['Accept'], 'application/geo+json');
          expect(jsonDecode(request.body), {
            'locations': [
              [77.5946, 12.9716],
            ],
            'range_type': 'time',
            'location_type': 'start',
            'range': [1.5],
          });
          return http.Response(jsonEncode(fixture), 200);
        });
        addTearDown(client.close);
        final result = await IsochroneRepository(client: client).getIsochrone(
          origin: origin,
          travelMode: entry.key,
          travelTime: const Duration(milliseconds: 1500),
        );
        expect(calls, 1);
        expect(result.geoJson, fixture);
        expect(result.origin, origin);
        expect(result.travelMode, entry.key);
        expect(result.travelTime, const Duration(milliseconds: 1500));
      },
    );
  }

  test(
    'preserves Polygon outer ring, holes, properties and metadata immutably',
    () async {
      final fixture = collection();
      final result = await retrieve(fixture);
      expect(result.geoJson, fixture);
      expect(() => result.geoJson['type'] = 'changed', throwsUnsupportedError);
      final rings =
          result.geoJson['features'][0]['geometry']['coordinates'] as List;
      expect(rings, [outer, hole]);
      expect(() => rings[1][0][0] = 0, throwsUnsupportedError);
    },
  );

  test(
    'preserves MultiPolygon components and holes without flattening',
    () async {
      final fixture = collection(
        type: 'MultiPolygon',
        coordinates: [
          [outer, hole],
          [island],
        ],
      );
      expect((await retrieve(fixture)).geoJson, fixture);
    },
  );

  test(
    'preserves multiple features and additional coordinate ordinates',
    () async {
      final fixture = collection(
        coordinates: [
          outer.map((p) => [...p, 800]).toList(),
        ],
      );
      (fixture['features'] as List).add(collection()['features'][0]);
      expect((await retrieve(fixture)).geoJson, fixture);
    },
  );

  for (final duration in [Duration.zero, const Duration(seconds: -1)]) {
    test('rejects nonpositive threshold $duration without a request', () async {
      final client = MockClient(
        (_) async => throw StateError('Must not request'),
      );
      addTearDown(client.close);
      await expectLater(
        IsochroneRepository(client: client).getIsochrone(
          origin: origin,
          travelMode: TravelMode.driving,
          travelTime: duration,
        ),
        throwsA(failure(IsochroneFailure.invalidInput)),
      );
    });
  }

  for (final coordinate in [
    InvalidOrigin(double.nan, 77),
    InvalidOrigin(12, double.infinity),
    InvalidOrigin(91, 77),
    InvalidOrigin(12, 181),
  ]) {
    test(
      'rejects invalid WGS84 origin ${coordinate.latitude}/${coordinate.longitude}',
      () async {
        final client = MockClient(
          (_) async => throw StateError('Must not request'),
        );
        addTearDown(client.close);
        await expectLater(
          IsochroneRepository(client: client).getIsochrone(
            origin: coordinate,
            travelMode: TravelMode.driving,
            travelTime: threshold,
          ),
          throwsA(failure(IsochroneFailure.invalidInput)),
        );
      },
    );
  }

  test('rejects unsupported motorcycle mode without a request', () async {
    final client = MockClient(
      (_) async => throw StateError('Must not request'),
    );
    addTearDown(client.close);
    await expectLater(
      IsochroneRepository(client: client).getIsochrone(
        origin: origin,
        travelMode: TravelMode.twoWheeler,
        travelTime: threshold,
      ),
      throwsA(failure(IsochroneFailure.unsupportedMode)),
    );
  });

  test('rejects invalid timeout configuration', () {
    for (final timeout in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => IsochroneRepository(timeout: timeout),
        throwsA(failure(IsochroneFailure.invalidInput)),
      );
    }
  });

  test(
    'empty results explicitly fail rather than synthesizing a shape',
    () async {
      await expectLater(
        retrieve({'type': 'FeatureCollection', 'features': []}),
        throwsA(failure(IsochroneFailure.emptyResult)),
      );
    },
  );

  final malformed = <String, dynamic>{
    'non-object': [],
    'wrong collection type': {'type': 'Feature', 'features': []},
    'missing features': {'type': 'FeatureCollection'},
    'null feature': {
      'type': 'FeatureCollection',
      'features': [null],
    },
    'wrong feature type': {
      'type': 'FeatureCollection',
      'features': [
        {'type': 'Polygon'},
      ],
    },
    'null geometry': collection()..['features'][0]['geometry'] = null,
    'unsupported geometry': collection(type: 'LineString', coordinates: outer),
    'empty polygon': collection(coordinates: []),
    'empty multipolygon': collection(type: 'MultiPolygon', coordinates: []),
    'empty component': collection(type: 'MultiPolygon', coordinates: [[]]),
    'short ring': collection(
      coordinates: [
        [
          [77, 12],
          [78, 13],
          [77, 12],
        ],
      ],
    ),
    'open ring': collection(
      coordinates: [
        [
          [77, 12],
          [78, 12],
          [78, 13],
          [77, 13],
        ],
      ],
    ),
    'bad coordinate': collection(
      coordinates: [
        [
          [181, 12],
          [78, 12],
          [78, 13],
          [181, 12],
        ],
      ],
    ),
    'nonnumeric coordinate': collection(
      coordinates: [
        [
          ['77', 12],
          [78, 12],
          [78, 13],
          ['77', 12],
        ],
      ],
    ),
    'wrong range': collection(value: 300),
    'wrong origin group': collection()
      ..['features'][0]['properties']['group_index'] = 1,
    'missing properties': collection()..['features'][0]['properties'] = null,
    'missing value': collection()
      ..['features'][0]['properties'].remove('value'),
  };
  for (final entry in malformed.entries) {
    test('rejects malformed response: ${entry.key}', () async {
      await expectLater(
        retrieve(entry.value),
        throwsA(failure(IsochroneFailure.malformedResponse)),
      );
    });
  }

  test('non-JSON successful response is malformed', () async {
    final client = MockClient(
      (_) async => http.Response('<html>invalid</html>', 200),
    );
    addTearDown(client.close);
    await expectLater(
      IsochroneRepository(client: client).getIsochrone(
        origin: origin,
        travelMode: TravelMode.walking,
        travelTime: threshold,
      ),
      throwsA(failure(IsochroneFailure.malformedResponse)),
    );
  });

  test(
    'unsnappable/unreachable provider error retains status, code and message',
    () async {
      await expectLater(
        retrieve({
          'error': {
            'code': 3099,
            'message': 'Unable to build an isochrone map.',
          },
        }, status: 500),
        throwsA(
          failure(IsochroneFailure.requestFailed)
              .having((e) => e.statusCode, 'status', 500)
              .having((e) => e.providerCode, 'code', 3099)
              .having(
                (e) => e.message,
                'message',
                'Unable to build an isochrone map.',
              ),
        ),
      );
    },
  );

  for (final status in [400, 401, 403, 429, 503]) {
    test('HTTP $status fails without retry and retains Retry-After', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response(
          'non-JSON error',
          status,
          headers: {'retry-after': '60'},
        );
      });
      addTearDown(client.close);
      await expectLater(
        IsochroneRepository(client: client).getIsochrone(
          origin: origin,
          travelMode: TravelMode.walking,
          travelTime: threshold,
        ),
        throwsA(
          failure(IsochroneFailure.requestFailed)
              .having((e) => e.statusCode, 'status', status)
              .having((e) => e.retryAfter, 'retryAfter', '60'),
        ),
      );
      expect(calls, 1);
    });
  }

  test('provider error in HTTP 200 is still a failure', () async {
    await expectLater(
      retrieve({
        'error': {'code': 3004, 'message': 'Range limit exceeded'},
      }),
      throwsA(
        failure(
          IsochroneFailure.requestFailed,
        ).having((e) => e.providerCode, 'code', 3004),
      ),
    );
  });

  test('transport failure is explicit', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    addTearDown(client.close);
    await expectLater(
      IsochroneRepository(client: client).getIsochrone(
        origin: origin,
        travelMode: TravelMode.walking,
        travelTime: threshold,
      ),
      throwsA(failure(IsochroneFailure.requestFailed)),
    );
  });

  test('a stalled request times out', () async {
    final client = MockClient((_) => Completer<http.Response>().future);
    addTearDown(client.close);
    await expectLater(
      IsochroneRepository(
        client: client,
        timeout: const Duration(milliseconds: 1),
      ).getIsochrone(
        origin: origin,
        travelMode: TravelMode.walking,
        travelTime: threshold,
      ),
      throwsA(failure(IsochroneFailure.timeout)),
    );
  });
}

// LatLng itself asserts bounds in debug mode. Override getters to exercise the
// repository's defensive checks independently of constructor assertions.
class InvalidOrigin extends LatLng {
  final double invalidLatitude;
  final double invalidLongitude;
  InvalidOrigin(this.invalidLatitude, this.invalidLongitude) : super(0, 0);
  @override
  double get latitude => invalidLatitude;
  @override
  double get longitude => invalidLongitude;
}
