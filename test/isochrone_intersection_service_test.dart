import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rendezvous_app/models/road_network_isochrone.dart';
import 'package:rendezvous_app/models/user_location.dart';
import 'package:rendezvous_app/services/isochrone_intersection_service.dart';

import 'fixtures/intersection_fixtures.dart';

Map<String, dynamic> world(Map geometry) {
  dynamic transform(dynamic v) {
    if (v is List && v.length == 2 && v.first is num) {
      return [77 + (v[0] as num) / 1000, 12 + (v[1] as num) / 1000];
    }
    return (v as List).map(transform).toList();
  }

  return {
    'type': geometry['type'],
    'coordinates': transform(geometry['coordinates']),
  };
}

RoadNetworkIsochrone isochrone(Map<String, dynamic> geometry) =>
    RoadNetworkIsochrone(
      origin: const LatLng(12, 77),
      travelMode: TravelMode.walking,
      travelTime: const Duration(seconds: 600),
      geoJson: {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': <String, dynamic>{},
            'geometry': geometry,
          },
        ],
      },
    );

Map<String, dynamic> polygon(List rings) => {
  'type': 'Polygon',
  'coordinates': rings,
};
Map<String, dynamic> rectangle(num x0, num y0, num x1, num y1) => world(
  polygon([
    [
      [x0, y0],
      [x1, y0],
      [x1, y1],
      [x0, y1],
      [x0, y0],
    ],
  ]),
);

// Independent comparison: normalize only winding, cyclic start, collinear
// vertices and component ordering. No clipping/point-in-polygon code is reused.
String canonical(Map<String, dynamic> geometry) {
  String ringKey(List ring) {
    final points = ring
        .take(ring.length - 1)
        .map(
          (p) => [((p[0] as num) * 1e7).round(), ((p[1] as num) * 1e7).round()],
        )
        .toList();
    var changed = true;
    while (changed && points.length > 3) {
      changed = false;
      for (var i = 0; i < points.length; i++) {
        final a = points[(i + points.length - 1) % points.length],
            b = points[i],
            c = points[(i + 1) % points.length];
        final cross =
            BigInt.from(b[0] - a[0]) * BigInt.from(c[1] - b[1]) -
            BigInt.from(b[1] - a[1]) * BigInt.from(c[0] - b[0]);
        if (cross == BigInt.zero) {
          points.removeAt(i);
          changed = true;
          break;
        }
      }
    }
    final variants = <String>[];
    for (final sequence in [points, points.reversed.toList()]) {
      for (var i = 0; i < sequence.length; i++) {
        variants.add(jsonEncode([...sequence.skip(i), ...sequence.take(i)]));
      }
    }
    variants.sort();
    return variants.first;
  }

  final polygons = geometry['type'] == 'Polygon'
      ? [geometry['coordinates']]
      : geometry['coordinates'] as List;
  final keys = <String>[];
  for (final poly in polygons) {
    final rings = poly as List;
    final holes = rings.skip(1).map((r) => ringKey(r as List)).toList()..sort();
    keys.add(jsonEncode([ringKey(rings.first as List), ...holes]));
  }
  keys.sort();
  return jsonEncode(keys);
}

void main() {
  final service = IsochroneIntersectionService();
  final fixtures = jsonDecode(intersectionFixturesJson)['fixtures'] as List;
  for (final fixture in fixtures) {
    for (final reverse in [false, true]) {
      test('GEOS oracle: ${fixture['name']} (reverse=$reverse)', () {
        final inputs = (fixture['inputs'] as List)
            .map((g) => isochrone(world(g as Map)))
            .toList();
        final result = service.intersect(
          reverse ? inputs.reversed.toList() : inputs,
        );
        expect(result.participantCount, inputs.length);
        expect(result.gridSizeDegrees, 1e-7);
        if (fixture['expected'] == null) {
          expect(result.isEmpty, isTrue);
          expect(result.geometry, isNull);
        } else {
          expect(result.isEmpty, isFalse);
          expect(
            canonical(result.geometry!),
            canonical(world(fixture['expected'] as Map)),
          );
        }
      });
    }
  }

  test('output is immutable and longitude/latitude are not swapped', () {
    final result = service.intersect([
      isochrone(rectangle(0, 0, 4, 4)),
      isochrone(rectangle(2, 1, 6, 3)),
    ]);
    final points = result.geometry!['coordinates'][0] as List;
    expect(
      points.every((p) => (p[0] as num) >= 77 && (p[1] as num) < 13),
      isTrue,
    );
    expect(() => points[0][0] = 0, throwsUnsupportedError);
  });

  test('ring winding has no effect on shell/hole semantics', () {
    final fixture = fixtures.firstWhere((f) => f['name'] == 'hole preserved');
    final original = world(fixture['inputs'][0]);
    original['coordinates'] = (original['coordinates'] as List)
        .map((r) => (r as List).reversed.toList())
        .toList();
    final result = service.intersect([
      isochrone(original),
      isochrone(world(fixture['inputs'][1])),
    ]);
    expect(canonical(result.geometry!), canonical(world(fixture['expected'])));
  });

  test('distinct features within one participant are unioned', () {
    final first = isochrone(rectangle(0, 0, 3, 3));
    final second = isochrone(rectangle(2, 0, 4, 3));
    final combined = RoadNetworkIsochrone(
      origin: first.origin,
      travelMode: first.travelMode,
      travelTime: first.travelTime,
      geoJson: {
        'type': 'FeatureCollection',
        'features': [
          ...first.geoJson['features'] as List,
          ...second.geoJson['features'] as List,
        ],
      },
    );
    final result = service.intersect([
      combined,
      isochrone(rectangle(1, 1, 5, 2)),
    ]);
    expect(canonical(result.geometry!), canonical(rectangle(1, 1, 4, 2)));
  });

  for (final count in [0, 1, 21]) {
    test('rejects $count participants', () {
      expect(
        () => service.intersect(
          List.generate(count, (_) => isochrone(rectangle(0, 0, 1, 1))),
        ),
        throwsA(
          isA<IsochroneIntersectionException>().having(
            (e) => e.kind,
            'kind',
            IntersectionFailure.invalidInput,
          ),
        ),
      );
    });
  }

  final invalid = <String, Map<String, dynamic>>{
    'open ring': world(
      polygon([
        [
          [0, 0],
          [4, 0],
          [4, 4],
          [0, 4],
        ],
      ]),
    ),
    'short ring': world(
      polygon([
        [
          [0, 0],
          [4, 0],
          [0, 0],
        ],
      ]),
    ),
    'zero area': world(
      polygon([
        [
          [0, 0],
          [1, 0],
          [2, 0],
          [0, 0],
        ],
      ]),
    ),
    'self crossing': world(
      polygon([
        [
          [0, 0],
          [4, 4],
          [0, 4],
          [4, 0],
          [0, 0],
        ],
      ]),
    ),
    'hole outside shell': world(
      polygon([
        [
          [0, 0],
          [4, 0],
          [4, 4],
          [0, 4],
          [0, 0],
        ],
        [
          [5, 5],
          [6, 5],
          [6, 6],
          [5, 5],
        ],
      ]),
    ),
    'overlapping holes': world(
      polygon([
        [
          [0, 0],
          [10, 0],
          [10, 10],
          [0, 10],
          [0, 0],
        ],
        [
          [1, 1],
          [4, 1],
          [4, 4],
          [1, 4],
          [1, 1],
        ],
        [
          [3, 3],
          [6, 3],
          [6, 6],
          [3, 6],
          [3, 3],
        ],
      ]),
    ),
    'nested holes': world(
      polygon([
        [
          [0, 0],
          [10, 0],
          [10, 10],
          [0, 10],
          [0, 0],
        ],
        [
          [1, 1],
          [8, 1],
          [8, 8],
          [1, 8],
          [1, 1],
        ],
        [
          [3, 3],
          [6, 3],
          [6, 6],
          [3, 6],
          [3, 3],
        ],
      ]),
    ),
    'overlapping multipolygon': {
      'type': 'MultiPolygon',
      'coordinates': [
        rectangle(0, 0, 3, 3)['coordinates'],
        rectangle(2, 2, 4, 4)['coordinates'],
      ],
    },
    'empty polygon': polygon([]),
    'empty multipolygon': {'type': 'MultiPolygon', 'coordinates': []},
    'wrong type': {'type': 'LineString', 'coordinates': []},
    'missing coordinates': {'type': 'Polygon'},
    'nonnumeric coordinate': polygon([
      [
        ['bad', 12],
        [77, 12],
        [77, 13],
        ['bad', 12],
      ],
    ]),
    'nonfinite coordinate': polygon([
      [
        [double.nan, 12],
        [77, 12],
        [77, 13],
        [double.nan, 12],
      ],
    ]),
    'wrong dimension': polygon([
      [
        [77, 12, 1],
        [78, 12, 1],
        [78, 13, 1],
        [77, 12, 1],
      ],
    ]),
  };
  for (final entry in invalid.entries) {
    test('rejects invalid geometry: ${entry.key}', () {
      expect(
        () => service.intersect([
          isochrone(rectangle(0, 0, 10, 10)),
          isochrone(entry.value),
        ]),
        throwsA(
          isA<IsochroneIntersectionException>()
              .having((e) => e.kind, 'kind', IntersectionFailure.invalidInput)
              .having((e) => e.participantIndex, 'participantIndex', 1),
        ),
      );
    });
  }

  test('does not skip invalid later participants after an empty pair', () {
    expect(
      () => service.intersect([
        isochrone(rectangle(0, 0, 1, 1)),
        isochrone(rectangle(2, 2, 3, 3)),
        isochrone(invalid['self crossing']!),
      ]),
      throwsA(
        isA<IsochroneIntersectionException>().having(
          (e) => e.participantIndex,
          'index',
          2,
        ),
      ),
    );
  });

  for (final json in [
    <String, dynamic>{},
    {'type': 'FeatureCollection', 'features': []},
    {
      'type': 'FeatureCollection',
      'features': [null],
    },
    {
      'type': 'FeatureCollection',
      'features': [
        {'type': 'Feature', 'geometry': null},
      ],
    },
  ]) {
    test('rejects malformed collection ${jsonEncode(json)}', () {
      final bad = RoadNetworkIsochrone(
        origin: const LatLng(12, 77),
        travelMode: TravelMode.walking,
        travelTime: const Duration(seconds: 600),
        geoJson: json,
      );
      expect(
        () => service.intersect([isochrone(rectangle(0, 0, 1, 1)), bad]),
        throwsA(isA<IsochroneIntersectionException>()),
      );
    });
  }

  test('rejects tiny input rings rather than silently losing a component', () {
    final tiny = polygon([
      [
        [77, 12],
        [77.0000001, 12],
        [77, 12.0000001],
        [77, 12],
      ],
    ]);
    expect(
      () => service.intersect([
        isochrone(rectangle(0, 0, 1, 1)),
        isochrone(tiny),
      ]),
      throwsA(
        isA<IsochroneIntersectionException>().having(
          (e) => e.kind,
          'kind',
          IntersectionFailure.unsupportedPrecision,
        ),
      ),
    );
  });

  test('rejects off-grid vertices instead of silently rounding them', () {
    final offGrid = polygon([
      [
        [77.00000001, 12],
        [77.01, 12],
        [77.01, 12.01],
        [77.00000001, 12],
      ],
    ]);
    expect(
      () => service.intersect([
        isochrone(rectangle(0, 0, 1, 1)),
        isochrone(offGrid),
      ]),
      throwsA(
        isA<IsochroneIntersectionException>().having(
          (e) => e.kind,
          'kind',
          IntersectionFailure.unsupportedPrecision,
        ),
      ),
    );
  });

  test(
    'rejects global extents rather than overflowing web integer arithmetic',
    () {
      expect(
        () => service.intersect([
          isochrone(rectangle(0, 0, 1, 1)),
          isochrone(rectangle(2000, 0, 2001, 1)),
        ]),
        throwsA(
          isA<IsochroneIntersectionException>().having(
            (e) => e.kind,
            'kind',
            IntersectionFailure.unsupportedPrecision,
          ),
        ),
      );
    },
  );
}
