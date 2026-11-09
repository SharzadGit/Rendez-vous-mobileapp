import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:rendezvous_app/models/research_venue.dart';
import 'package:rendezvous_app/services/venue_selection_service.dart';

List<List<double>> box(double a, double b, double c, double d) => [
  [a, b],
  [c, b],
  [c, d],
  [a, d],
  [a, b],
];
Map<String, dynamic> polygon(List rings) => {
  'type': 'Polygon',
  'coordinates': rings,
};
ResearchVenue venue(
  String id,
  double x,
  double y, {
  String category = 'cafe',
}) => ResearchVenue(
  id: id,
  name: id,
  category: category,
  longitude: x,
  latitude: y,
);
void main() {
  final service = VenueSelectionService();
  final square = polygon([box(77, 12, 77.1, 12.1)]);
  VenueSelectionResult select(
    Map<String, dynamic>? g,
    List<ResearchVenue> v, {
    bool boundary = false,
  }) => service.select(
    region: g,
    candidates: v,
    policy: VenueEligibilityPolicy(
      id: 'cafes-v1',
      categories: {'cafe'},
      includeBoundary: boundary,
    ),
  );
  test('interior, exterior, categories and stable ID ordering', () {
    final venues = [
      venue('z', 77.02, 12.02),
      venue('a', 77.03, 12.03),
      venue('out', 78, 12),
      venue('park', 77.04, 12.04, category: 'park'),
    ];
    expect(select(square, venues).venues.map((v) => v.id), ['a', 'z']);
    expect(select(square, venues.reversed.toList()).venues.map((v) => v.id), [
      'a',
      'z',
    ]);
  });
  for (final include in [false, true]) {
    test('shell and hole boundary rule $include', () {
      final g = polygon([
        box(77, 12, 77.1, 12.1),
        box(77.02, 12.02, 77.04, 12.04),
      ]);
      expect(select(g, [venue('hole', 77.03, 12.03)]).venues, isEmpty);
      expect(
        select(g, [
          venue('edge', 77.02, 12.03),
          venue('shell', 77, 12.05),
        ], boundary: include).venues.length,
        include ? 2 : 0,
      );
    });
  }
  test('concave notch excluded', () {
    final g = polygon([
      [
        [77.0, 12.0],
        [77.1, 12.0],
        [77.1, 12.04],
        [77.04, 12.04],
        [77.04, 12.1],
        [77.0, 12.1],
        [77.0, 12.0],
      ],
    ]);
    expect(
      select(g, [
        venue('inside', 77.02, 12.08),
        venue('notch', 77.08, 12.08),
      ]).venues.map((v) => v.id),
      ['inside'],
    );
  });
  test('disconnected multipolygon', () {
    final g = {
      'type': 'MultiPolygon',
      'coordinates': [
        [box(77, 12, 77.1, 12.1)],
        [box(77.2, 12, 77.3, 12.1)],
      ],
    };
    expect(
      select(g, [
        venue('b', 77.25, 12.05),
        venue('a', 77.05, 12.05),
        venue('gap', 77.15, 12.05),
      ]).venues.map((v) => v.id),
      ['a', 'b'],
    );
  });
  test('empty region and candidates', () {
    expect(select(null, []).status, VenueSelectionStatus.noEligibleVenues);
    expect(select(square, []).status, VenueSelectionStatus.noEligibleVenues);
  });
  test('duplicates rejected even with empty region', () {
    expect(
      select(null, [venue('x', 77, 12), venue('x', 77, 12)]).status,
      VenueSelectionStatus.invalidData,
    );
  });
  test('invalid coordinate rejected', () {
    expect(
      select(square, [venue('x', double.nan, 12)]).status,
      VenueSelectionStatus.invalidData,
    );
  });
  for (final g in [
    polygon([]),
    polygon([
      [
        [77, 12],
        [77.1, 12],
        [77, 12.1],
      ],
    ]),
    polygon([
      [
        [77, 12],
        [77.1, 12.1],
        [77, 12.1],
        [77.1, 12],
        [77, 12],
      ],
    ]),
    {
      'type': 'Point',
      'coordinates': [77, 12],
    },
    polygon([box(77, 12, 79, 13)]),
  ]) {
    test('reject malformed geometry ${jsonEncode(g)}', () {
      expect(select(g, []).status, VenueSelectionStatus.geometryFailure);
    });
  }
  Map<String, dynamic> dataset() => {
    'type': 'FeatureCollection',
    'dataset_version': 'fixture-v1',
    'metadata': {
      'source': 'offline test fixture',
      'extraction_date': '2026-01-01',
      'filtering_policy': 'cafes-v1',
    },
    'features': [
      {
        'type': 'Feature',
        'id': 'v1',
        'geometry': {
          'type': 'Point',
          'coordinates': [77.05, 12.05],
        },
        'properties': {
          'name': 'Fixture',
          'category': 'cafe',
          'osm_id': 'node/123',
        },
      },
    ],
  };
  test('dataset preserves supplied provenance and coordinates', () {
    final d = VenueDataset.fromGeoJson(jsonEncode(dataset()));
    expect(d.version, 'fixture-v1');
    expect(d.venues.single.longitude, 77.05);
    expect(d.venues.single.osmId, 'node/123');
    expect(d.metadata['filtering_policy'], 'cafes-v1');
    expect(() => d.metadata.clear(), throwsUnsupportedError);
  });
  test('missing provenance is absent, not fabricated', () {
    final raw = dataset()..remove('metadata');
    final d = VenueDataset.fromGeoJson(jsonEncode(raw));
    expect(d.metadata, isEmpty);
  });
  test('missing required version rejected', () {
    expect(
      () => VenueDataset.fromGeoJson(
        jsonEncode(dataset()..remove('dataset_version')),
      ),
      throwsFormatException,
    );
  });
  test('duplicate dataset IDs rejected', () {
    final d = dataset();
    (d['features'] as List).add((d['features'] as List).first);
    expect(
      () => VenueDataset.fromGeoJson(jsonEncode(d)),
      throwsFormatException,
    );
  });
}
