import 'package:clipper2/clipper2.dart' as clip;
import 'package:dart_jts/dart_jts.dart' as jts;

import '../models/road_network_isochrone.dart';

enum IntersectionFailure {
  invalidInput,
  unsupportedPrecision,
  computationFailed,
}

class IsochroneIntersectionException implements Exception {
  final IntersectionFailure kind;
  final String message;
  final int? participantIndex;

  const IsochroneIntersectionException(
    this.kind,
    this.message, {
    this.participantIndex,
  });

  @override
  String toString() =>
      'IsochroneIntersectionException(${kind.name}, '
      'participant=$participantIndex): $message';
}

/// Positive-area overlap only. Null geometry explicitly means no shared area.
/// Coordinates describe the documented finite-precision grid, not exact reals.
class IsochroneIntersectionResult {
  final Map<String, dynamic>? geometry;
  final int participantCount;
  final double gridSizeDegrees = 1e-7;
  bool get isEmpty => geometry == null;

  IsochroneIntersectionResult._(
    Map<String, dynamic>? geometry,
    this.participantCount,
  ) : geometry = geometry == null
          ? null
          : _freeze(geometry) as Map<String, dynamic>;

  static dynamic _freeze(dynamic value) {
    if (value is Map<String, dynamic>) {
      return Map<String, dynamic>.unmodifiable(
        value.map((k, v) => MapEntry(k, _freeze(v))),
      );
    }
    if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
    return value;
  }
}

/// Offline area intersection, independent of routing and optimization.
///
/// Planar GeoJSON segments, x=longitude/y=latitude. See
/// docs/isochrone-intersection.md for the mandatory precision/domain contract.
class IsochroneIntersectionService {
  static const int _scale = 10000000;
  static final _factory = jts.GeometryFactory.defaultPrecision();

  IsochroneIntersectionResult intersect(List<RoadNetworkIsochrone> isochrones) {
    if (isochrones.length < 2 || isochrones.length > 20) {
      _fail(
        IntersectionFailure.invalidInput,
        'Expected 2–20 participant isochrones.',
      );
    }
    // Validate every participant before allowing an early empty result.
    final participants = <List<List<List<List<double>>>>>[];
    for (var i = 0; i < isochrones.length; i++) {
      participants.add(_read(isochrones[i].geoJson, i));
    }
    final points = participants
        .expand((p) => p)
        .expand((p) => p)
        .expand((r) => r);
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (final p in points) {
      if (p[0] < minX) minX = p[0];
      if (p[0] > maxX) maxX = p[0];
      if (p[1] < minY) minY = p[1];
      if (p[1] > maxY) maxY = p[1];
    }
    if (maxX - minX > 1 || maxY - minY > 1) {
      _fail(
        IntersectionFailure.unsupportedPrecision,
        'Combined extent must not exceed one degree on either axis; '
        'global, polar and antimeridian geometry is unsupported.',
      );
    }
    final anchorX = ((minX + maxX) * _scale / 2).round();
    final anchorY = ((minY + maxY) * _scale / 2).round();

    try {
      final groups = <clip.Paths64>[];
      for (var i = 0; i < participants.length; i++) {
        final polygons = participants[i]
            .map(
              (polygon) => polygon
                  .map(
                    (ring) => ring
                        .take(ring.length - 1)
                        .map(
                          (p) => clip.Point64(
                            (p[0] * _scale).round() - anchorX,
                            (p[1] * _scale).round() - anchorY,
                          ),
                        )
                        .toList(),
                  )
                  .toList(),
            )
            .toList();
        for (final polygon in polygons) {
          _validateTopology([polygon], i);
        }
        final paths = <clip.Path64>[];
        for (final polygon in polygons) {
          for (var r = 0; r < polygon.length; r++) {
            final path = polygon[r];
            final area = _twiceArea(path);
            if (area == BigInt.zero) {
              _fail(IntersectionFailure.invalidInput, 'Ring has zero area.', i);
            }
            if (area.abs() < BigInt.from(4)) {
              _fail(
                IntersectionFailure.unsupportedPrecision,
                'Input rings need at least two square grid units of area.',
                i,
              );
            }
            // Ring winding is representational, not a repair. NonZero filling
            // requires shells and holes to have opposite orientations.
            paths.add(
              (area.isNegative == (r == 0)) ? path.reversed.toList() : path,
            );
          }
        }
        // A participant's FeatureCollection represents the union of features.
        // Each individual Polygon/MultiPolygon was validated before this union.
        final union = _execute(paths, const [], clip.ClipType.union);
        final unionPaths = _paths(union);
        if (unionPaths.isEmpty) {
          _fail(
            IntersectionFailure.computationFailed,
            'Clipping erased a positive-area participant geometry.',
            i,
          );
        }
        _validateTopology(_polygons(union), i, output: true);
        groups.add(unionPaths);
      }
      var shared = groups.first;
      clip.PolyTree64? tree;
      for (final group in groups.skip(1)) {
        tree = _execute(shared, group, clip.ClipType.intersection);
        shared = _paths(tree);
        if (shared.isEmpty) {
          return IsochroneIntersectionResult._(null, isochrones.length);
        }
      }
      final polygons = _polygons(tree!);
      // Reject numerically invalid output, never buffer(0), snap or repair it.
      _validateTopology(polygons, null, output: true);
      final coordinates = polygons
          .map(
            (polygon) => polygon.map((ring) {
              final closed = [...ring, ring.first];
              return closed
                  .map(
                    (p) => [(p.x + anchorX) / _scale, (p.y + anchorY) / _scale],
                  )
                  .toList();
            }).toList(),
          )
          .toList();
      return IsochroneIntersectionResult._({
        'type': coordinates.length == 1 ? 'Polygon' : 'MultiPolygon',
        'coordinates': coordinates.length == 1
            ? coordinates.single
            : coordinates,
      }, isochrones.length);
    } on IsochroneIntersectionException {
      rethrow;
    } catch (error) {
      _fail(
        IntersectionFailure.computationFailed,
        'Geometry engine failed: $error',
      );
    }
  }

  static List<List<List<List<double>>>> _read(
    Map<String, dynamic> json,
    int index,
  ) {
    if (json['type'] != 'FeatureCollection' ||
        json['features'] is! List ||
        (json['features'] as List).isEmpty) {
      _fail(
        IntersectionFailure.invalidInput,
        'Expected nonempty FeatureCollection.',
        index,
      );
    }
    final result = <List<List<List<double>>>>[];
    for (final feature in json['features'] as List) {
      if (feature is! Map ||
          feature['type'] != 'Feature' ||
          feature['geometry'] is! Map) {
        _fail(IntersectionFailure.invalidInput, 'Malformed feature.', index);
      }
      final geometry = feature['geometry'] as Map;
      final List polygons;
      switch (geometry['type']) {
        case 'Polygon':
          polygons = [geometry['coordinates']];
        case 'MultiPolygon':
          if (geometry['coordinates'] is! List) {
            _fail(
              IntersectionFailure.invalidInput,
              'Malformed MultiPolygon.',
              index,
            );
          }
          polygons = geometry['coordinates'] as List;
        default:
          _fail(
            IntersectionFailure.invalidInput,
            'Only Polygon/MultiPolygon supported.',
            index,
          );
      }
      if (polygons.isEmpty) {
        _fail(IntersectionFailure.invalidInput, 'Empty geometry.', index);
      }
      final parsed = <List<List<List<double>>>>[];
      for (final polygon in polygons) {
        if (polygon is! List || polygon.isEmpty) {
          _fail(
            IntersectionFailure.invalidInput,
            'Polygon has no rings.',
            index,
          );
        }
        final rings = <List<List<double>>>[];
        for (final ring in polygon) {
          if (ring is! List || ring.length < 4) {
            _fail(
              IntersectionFailure.invalidInput,
              'Ring needs at least four positions.',
              index,
            );
          }
          final positions = <List<double>>[];
          for (final position in ring) {
            if (position is! List ||
                position.length != 2 ||
                position.any((v) => v is! num || !v.isFinite)) {
              _fail(
                IntersectionFailure.invalidInput,
                'Expected finite 2D positions.',
                index,
              );
            }
            final p = position.map((v) => (v as num).toDouble()).toList();
            if (p[0].abs() > 180 || p[1].abs() >= 90) {
              _fail(
                IntersectionFailure.invalidInput,
                'Invalid/nonlocal WGS84 position.',
                index,
              );
            }
            if (p.any(
              (v) => (v * _scale - (v * _scale).round()).abs() > 0.000001,
            )) {
              _fail(
                IntersectionFailure.unsupportedPrecision,
                'Input vertices must lie on the explicit 1e-7 degree grid.',
                index,
              );
            }
            positions.add(p);
          }
          if (positions.first[0] != positions.last[0] ||
              positions.first[1] != positions.last[1]) {
            _fail(
              IntersectionFailure.invalidInput,
              'Ring is not closed.',
              index,
            );
          }
          rings.add(positions);
        }
        parsed.add(rings);
      }
      // Validate feature components together: overlapping MultiPolygon interiors
      // are invalid, unlike overlapping areas in distinct GeoJSON features.
      _validateOriginalTopology(parsed, index);
      result.addAll(parsed);
    }
    return result;
  }

  static void _validateOriginalTopology(
    List<List<List<List<double>>>> polygons,
    int index,
  ) {
    final converted = polygons.map((polygon) {
      final rings = polygon
          .map(
            (ring) => _factory.createLinearRing(
              ring.map((p) => jts.Coordinate(p[0], p[1])).toList(),
            ),
          )
          .toList();
      return _factory.createPolygon(rings.first, rings.skip(1).toList());
    }).toList();
    try {
      final op = jts.IsValidOp(_factory.createMultiPolygon(converted));
      if (!op.isValid()) {
        _fail(
          IntersectionFailure.invalidInput,
          'Invalid topology: ${op.getValidationError()}',
          index,
        );
      }
    } on IsochroneIntersectionException {
      rethrow;
    } catch (error) {
      _fail(
        IntersectionFailure.computationFailed,
        'Topology validation failed: $error',
        index,
      );
    }
  }

  static void _validateTopology(
    List<List<clip.Path64>> polygons,
    int? index, {
    bool output = false,
  }) {
    final converted = polygons.map((polygon) {
      final rings = polygon
          .map(
            (ring) => _factory.createLinearRing(
              [...ring, ring.first]
                  .map((p) => jts.Coordinate(p.x.toDouble(), p.y.toDouble()))
                  .toList(),
            ),
          )
          .toList();
      return _factory.createPolygon(rings.first, rings.skip(1).toList());
    }).toList();
    final op = jts.IsValidOp(_factory.createMultiPolygon(converted));
    if (!op.isValid()) {
      _fail(
        output
            ? IntersectionFailure.computationFailed
            : IntersectionFailure.invalidInput,
        'Invalid ${output ? 'output' : 'grid'} topology: ${op.getValidationError()}',
        index,
      );
    }
  }

  static clip.PolyTree64 _execute(
    clip.Paths64 subject,
    clip.Paths64 other,
    clip.ClipType operation,
  ) {
    final engine = clip.Clipper64()
      ..addSubjects(subject)
      ..addClips(other);
    final solution = engine.executeTree(operation, clip.FillRule.nonZero);
    if (solution == null) {
      _fail(IntersectionFailure.computationFailed, 'Clipper failed.');
    }
    return solution.tree;
  }

  static List<List<clip.Path64>> _polygons(clip.PolyTree64 tree) {
    final result = <List<clip.Path64>>[];
    void visit(clip.PolyPath64 node) {
      if (node.polygon != null && !node.isHole) {
        result.add([
          node.polygon!,
          ...node.children.where((c) => c.isHole).map((c) => c.polygon!),
        ]);
      }
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(tree);
    return result;
  }

  static clip.Paths64 _paths(clip.PolyTree64 tree) =>
      _polygons(tree).expand((p) => p).toList();

  static BigInt _twiceArea(clip.Path64 path) {
    var sum = BigInt.zero;
    for (var i = 0; i < path.length; i++) {
      final a = path[i];
      final b = path[(i + 1) % path.length];
      sum +=
          BigInt.from(a.x) * BigInt.from(b.y) -
          BigInt.from(a.y) * BigInt.from(b.x);
    }
    return sum;
  }

  static Never _fail(IntersectionFailure kind, String message, [int? index]) =>
      throw IsochroneIntersectionException(
        kind,
        message,
        participantIndex: index,
      );
}
