import 'package:dart_jts/dart_jts.dart' as jts;
import '../models/research_venue.dart';

enum VenueSelectionStatus {
  selected,
  noEligibleVenues,
  invalidData,
  geometryFailure,
}

class VenueEligibilityPolicy {
  final String id;
  final Set<String> categories;
  final bool includeBoundary;
  VenueEligibilityPolicy({
    required this.id,
    required Set<String> categories,
    required this.includeBoundary,
  }) : categories = Set.unmodifiable(categories);
}

class VenueSelectionResult {
  final VenueSelectionStatus status;
  final List<ResearchVenue> venues;
  final String? error;
  VenueSelectionResult(this.status, List<ResearchVenue> venues, [this.error])
    : venues = List.unmodifiable(venues);
}

class VenueSelectionService {
  VenueSelectionResult select({
    required Map<String, dynamic>? region,
    required List<ResearchVenue> candidates,
    required VenueEligibilityPolicy policy,
  }) {
    try {
      validateVenues(candidates);
      if (policy.id.trim().isEmpty ||
          policy.categories.any((s) => s.trim().isEmpty)) {
        throw const FormatException('Invalid policy');
      }
    } catch (e) {
      return VenueSelectionResult(VenueSelectionStatus.invalidData, [], '$e');
    }
    try {
      if (region == null) {
        return VenueSelectionResult(VenueSelectionStatus.noEligibleVenues, []);
      }
      final geometry = _read(region);
      final locator = jts.PointLocator();
      final selected = candidates.where((v) {
        if (!policy.categories.contains(v.category)) return false;
        final location = locator.locate(
          jts.Coordinate(v.longitude, v.latitude),
          geometry,
        );
        return location == jts.Location.INTERIOR ||
            (policy.includeBoundary && location == jts.Location.BOUNDARY);
      }).toList()..sort((a, b) => a.id.compareTo(b.id));
      return VenueSelectionResult(
        selected.isEmpty
            ? VenueSelectionStatus.noEligibleVenues
            : VenueSelectionStatus.selected,
        selected,
      );
    } catch (e) {
      return VenueSelectionResult(
        VenueSelectionStatus.geometryFailure,
        [],
        '$e',
      );
    }
  }

  jts.Geometry _read(Map<String, dynamic> region) {
    final type = region['type'];
    if (type != 'Polygon' && type != 'MultiPolygon') {
      throw const FormatException('Expected Polygon or MultiPolygon');
    }
    final raw = type == 'Polygon'
        ? [region['coordinates']]
        : region['coordinates'] as List;
    if (raw.isEmpty) {
      throw const FormatException('Use null for empty intersection');
    }
    final factory = jts.GeometryFactory.defaultPrecision();
    final points = <jts.Coordinate>[];
    final polygons = raw.map((polygon) {
      final rings = (polygon as List).map((ring) {
        final coords = (ring as List).map((p) {
          if (p is! List || p.length != 2) {
            throw const FormatException('Expected 2D coordinate');
          }
          final x = (p[0] as num).toDouble(), y = (p[1] as num).toDouble();
          if (!x.isFinite ||
              !y.isFinite ||
              x.abs() >= 180 ||
              y.abs() >= 90 ||
              (x * 1e7 - (x * 1e7).round()).abs() > 1e-6 ||
              (y * 1e7 - (y * 1e7).round()).abs() > 1e-6) {
            throw const FormatException('Unsupported coordinate/grid');
          }
          final c = jts.Coordinate(x, y);
          points.add(c);
          return c;
        }).toList();
        if (coords.length < 4 ||
            coords.first.x != coords.last.x ||
            coords.first.y != coords.last.y) {
          throw const FormatException('Invalid ring');
        }
        return factory.createLinearRing(coords);
      }).toList();
      if (rings.isEmpty) throw const FormatException('Missing shell');
      return factory.createPolygon(rings.first, rings.skip(1).toList());
    }).toList();
    final xs = points.map((p) => p.x).toList()..sort();
    final ys = points.map((p) => p.y).toList()..sort();
    if (xs.last - xs.first > 1 || ys.last - ys.first > 1) {
      throw const FormatException('Extent exceeds one degree');
    }
    final geometry = factory.createMultiPolygon(polygons);
    if (!jts.IsValidOp(geometry).isValid()) {
      throw const FormatException('Invalid polygon topology');
    }
    return geometry;
  }
}
