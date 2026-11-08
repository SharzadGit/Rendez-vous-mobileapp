import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../config/api_keys.dart';
import '../models/road_network_isochrone.dart';
import '../models/user_location.dart';

enum IsochroneFailure {
  invalidInput,
  unsupportedMode,
  requestFailed,
  timeout,
  emptyResult,
  malformedResponse,
}

class IsochroneException implements Exception {
  final IsochroneFailure kind;
  final String message;
  final int? statusCode;
  final int? providerCode;
  final String? retryAfter;

  const IsochroneException(
    this.kind,
    this.message, {
    this.statusCode,
    this.providerCode,
    this.retryAfter,
  });

  @override
  String toString() => 'IsochroneException(${kind.name}): $message';
}

/// One origin and one threshold per call; never assumes a provider batch limit.
/// No automatic retries or geometry approximations. Injected clients are owned
/// by the caller, as in RoutingRepository. See docs/isochrone-retrieval.md.
class IsochroneRepository {
  final http.Client? _client;
  final Duration timeout;

  IsochroneRepository({
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client {
    if (timeout <= Duration.zero) {
      throw const IsochroneException(
        IsochroneFailure.invalidInput,
        'Request timeout must be positive.',
      );
    }
  }

  /// Retrieves outward road-network reachability, not routes toward the origin.
  /// Duration is encoded in seconds, including any fractional seconds.
  Future<RoadNetworkIsochrone> getIsochrone({
    required LatLng origin,
    required TravelMode travelMode,
    required Duration travelTime,
  }) async {
    if (!_validPosition([origin.longitude, origin.latitude]) ||
        travelTime <= Duration.zero) {
      throw const IsochroneException(
        IsochroneFailure.invalidInput,
        'Origin must be finite WGS84 coordinates and travel time positive.',
      );
    }
    final String profile;
    try {
      profile = travelMode.orsProfile;
    } on UnsupportedError {
      throw const IsochroneException(
        IsochroneFailure.unsupportedMode,
        'Motorcycle/two-wheeler isochrones are unsupported.',
      );
    }
    final seconds = travelTime.inMicroseconds / Duration.microsecondsPerSecond;
    final http.Response response;
    try {
      response = await (_client?.post ?? http.post)(
        Uri.parse('https://api.openrouteservice.org/v2/isochrones/$profile'),
        headers: {
          'Authorization': ApiKeys.ors,
          'Content-Type': 'application/json',
          'Accept': 'application/geo+json',
        },
        body: jsonEncode({
          'locations': [
            [origin.longitude, origin.latitude],
          ],
          'range_type': 'time',
          'location_type': 'start',
          'range': [seconds],
        }),
      ).timeout(timeout);
    } on TimeoutException {
      throw const IsochroneException(
        IsochroneFailure.timeout,
        'ORS isochrone request timed out.',
      );
    } on Exception catch (error) {
      throw IsochroneException(
        IsochroneFailure.requestFailed,
        'ORS isochrone transport failure: $error',
      );
    }

    dynamic data;
    try {
      data = jsonDecode(response.body);
    } on FormatException {
      if (response.statusCode == 200) {
        throw const IsochroneException(
          IsochroneFailure.malformedResponse,
          'ORS response is not valid JSON.',
        );
      }
    }
    final providerError = data is Map ? data['error'] : null;
    if (response.statusCode != 200 || providerError != null) {
      throw IsochroneException(
        IsochroneFailure.requestFailed,
        providerError is Map && providerError['message'] is String
            ? providerError['message'] as String
            : 'ORS isochrone request failed (HTTP ${response.statusCode}).',
        statusCode: response.statusCode,
        providerCode: providerError is Map && providerError['code'] is int
            ? providerError['code'] as int
            : null,
        retryAfter: response.headers['retry-after'],
      );
    }
    _validateCollection(data, seconds);
    return RoadNetworkIsochrone(
      origin: origin,
      travelMode: travelMode,
      travelTime: travelTime,
      geoJson: data as Map<String, dynamic>,
    );
  }

  static Never _malformed(String message) =>
      throw IsochroneException(IsochroneFailure.malformedResponse, message);

  static void _validateCollection(dynamic data, double seconds) {
    if (data is! Map<String, dynamic> ||
        data['type'] != 'FeatureCollection' ||
        data['features'] is! List) {
      _malformed('Expected a GeoJSON FeatureCollection.');
    }
    final features = data['features'] as List;
    if (features.isEmpty) {
      throw const IsochroneException(
        IsochroneFailure.emptyResult,
        'ORS returned no reachable area; the origin may be unreachable or unsnappable.',
      );
    }
    for (final feature in features) {
      if (feature is! Map || feature['type'] != 'Feature') {
        _malformed('Expected a GeoJSON Feature.');
      }
      final properties = feature['properties'];
      if (properties is! Map ||
          properties['group_index'] != 0 ||
          properties['value'] is! num ||
          !(properties['value'] as num).isFinite ||
          ((properties['value'] as num) - seconds).abs() > 0.000001) {
        _malformed(
          'Isochrone properties do not match the requested origin/range.',
        );
      }
      final geometry = feature['geometry'];
      if (geometry is! Map) _malformed('Missing isochrone geometry.');
      switch (geometry['type']) {
        case 'Polygon':
          _validatePolygon(geometry['coordinates']);
        case 'MultiPolygon':
          final polygons = geometry['coordinates'];
          if (polygons is! List || polygons.isEmpty) {
            _malformed('MultiPolygon must contain polygons.');
          }
          for (final polygon in polygons) {
            _validatePolygon(polygon);
          }
        default:
          _malformed('Expected Polygon or MultiPolygon geometry.');
      }
    }
  }

  // Structural validation only: do not repair, simplify, reorient or flatten.
  static void _validatePolygon(dynamic rings) {
    if (rings is! List || rings.isEmpty) {
      _malformed('Polygon must contain rings.');
    }
    for (final ring in rings) {
      if (ring is! List || ring.length < 4 || !ring.every(_validPosition)) {
        _malformed('A ring needs at least four valid WGS84 positions.');
      }
      final first = ring.first as List;
      final last = ring.last as List;
      if (first.length != last.length ||
          List.generate(
            first.length,
            (i) => i,
          ).any((i) => first[i] != last[i])) {
        _malformed('GeoJSON linear rings must be closed.');
      }
    }
  }

  static bool _validPosition(dynamic p) =>
      p is List &&
      p.length >= 2 &&
      p.every((v) => v is num && v.isFinite) &&
      (p[0] as num).abs() <= 180 &&
      (p[1] as num).abs() <= 90;
}
