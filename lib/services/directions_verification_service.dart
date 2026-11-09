import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';
import '../config/ors_endpoints.dart';
import '../models/research_venue.dart';
import '../models/user_location.dart';
import 'venue_routing_service.dart';

enum DirectionsStatus {
  success,
  unreachable,
  excessiveSnapping,
  thresholdViolation,
  malformedResponse,
  invalidInput,
  unsupportedMode,
  providerError,
  rateLimited,
  timeout,
  budgetExhausted,
}

class DirectionsConfig {
  final int maxRequests, maxVenues;
  final Duration timeout;
  final double maxStartSnapMetres, maxEndSnapMetres, thresholdToleranceSeconds;
  const DirectionsConfig({
    this.maxRequests = 100,
    this.maxVenues = 5,
    this.timeout = const Duration(seconds: 30),
    this.maxStartSnapMetres = 100,
    this.maxEndSnapMetres = 100,
    this.thresholdToleranceSeconds = 1e-6,
  });
}

class VerifiedRoute {
  final DirectionsStatus status;
  final String? reason, retryAfter;
  final int? httpStatus, providerCode;
  final bool requested;
  final Duration elapsed;
  final Map<String, dynamic>? response;
  final double? seconds, metres, startSnapMetres, endSnapMetres, matrixSeconds;
  final bool? thresholdSatisfied, snappingSatisfied;
  double? get absoluteDiscrepancySeconds =>
      seconds == null || matrixSeconds == null
      ? null
      : (seconds! - matrixSeconds!).abs();
  double? get percentageDiscrepancy =>
      absoluteDiscrepancySeconds == null || matrixSeconds == 0
      ? null
      : 100 * (absoluteDiscrepancySeconds! / matrixSeconds!);
  List<dynamic>? get routedStart => response == null
      ? null
      : response!['features'][0]['geometry']['coordinates'].first
            as List<dynamic>;
  List<dynamic>? get routedEnd => response == null
      ? null
      : response!['features'][0]['geometry']['coordinates'].last
            as List<dynamic>;
  VerifiedRoute(
    this.status, {
    this.reason,
    this.retryAfter,
    this.httpStatus,
    this.providerCode,
    this.requested = false,
    this.elapsed = Duration.zero,
    Map<String, dynamic>? response,
    this.seconds,
    this.metres,
    this.startSnapMetres,
    this.endSnapMetres,
    this.matrixSeconds,
    this.thresholdSatisfied,
    this.snappingSatisfied,
  }) : response = response == null
           ? null
           : freezeJson(response) as Map<String, dynamic>;
}

class VerifiedVenue {
  final ResearchVenue venue;
  final List<VerifiedRoute> routes;
  final bool? directionsThresholdVerified;
  VerifiedVenue(this.venue, List<VerifiedRoute> routes, double? threshold)
    : routes = List.unmodifiable(routes),
      directionsThresholdVerified = threshold == null
          ? null
          : routes.isNotEmpty &&
                routes.every(
                  (r) =>
                      r.status == DirectionsStatus.success &&
                      r.thresholdSatisfied == true,
                );
}

class DirectionsVerificationResult {
  final List<UserLocation> participants;
  final List<VerifiedVenue> venues;
  final Duration runtime;
  final String? inputError;
  DirectionsVerificationResult(
    List<UserLocation> participants,
    List<VerifiedVenue> venues,
    this.runtime,
    this.inputError,
  ) : participants = List.unmodifiable(participants),
      venues = List.unmodifiable(venues);
  Iterable<VerifiedRoute> get routes => venues.expand((v) => v.routes);
  int get actualRequests => routes.where((r) => r.requested).length;
  int get successfulRoutes =>
      routes.where((r) => r.status == DirectionsStatus.success).length;
  int get failedRoutes => routes.length - successfulRoutes;
}

/// Offline-testable verification of provider routes, not physical venue access.
class DirectionsVerificationService {
  final http.Client? client;
  DirectionsVerificationService({this.client});
  Future<DirectionsVerificationResult> verify({
    required List<UserLocation> participants,
    required List<ResearchVenue> shortlist,
    VenueRoutingResult? matrix,
    double? thresholdSeconds,
    DirectionsConfig config = const DirectionsConfig(),
  }) async {
    final watch = Stopwatch()..start();
    final users = List<UserLocation>.unmodifiable(participants),
        venues = List<ResearchVenue>.unmodifiable(shortlist);
    String? error;
    final matrixRows = <String, VenueTravelEvaluation>{};
    try {
      if (users.isEmpty ||
          venues.length > config.maxVenues ||
          config.maxVenues < 1 ||
          config.maxRequests < 0 ||
          config.timeout <= Duration.zero ||
          [
            config.maxStartSnapMetres,
            config.maxEndSnapMetres,
            config.thresholdToleranceSeconds,
          ].any((v) => !v.isFinite || v < 0) ||
          (thresholdSeconds != null &&
              (!thresholdSeconds.isFinite || thresholdSeconds < 0))) {
        throw const FormatException(
          'Invalid configuration or oversized shortlist',
        );
      }
      final ids = <String>{};
      for (final v in venues) {
        if (v.id.trim().isEmpty || !ids.add(v.id)) {
          throw const FormatException('Duplicate or missing venue ID');
        }
      }
      if (matrix != null) {
        if (matrix.inputError != null ||
            matrix.participants.length != users.length) {
          throw const FormatException('Matrix provenance mismatch');
        }
        for (var i = 0; i < users.length; i++) {
          final a = users[i], b = matrix.participants[i];
          if (a.id != b.id ||
              a.position.latitude != b.position.latitude ||
              a.position.longitude != b.position.longitude ||
              a.travelMode != b.travelMode) {
            throw const FormatException('Matrix participant mismatch');
          }
        }
        for (final row in matrix.venues) {
          if (matrixRows.containsKey(row.venue.id) ||
              row.pairs.length != users.length) {
            throw const FormatException('Invalid matrix rows');
          }
          matrixRows[row.venue.id] = row;
        }
        for (final v in venues) {
          final row = matrixRows[v.id];
          if (row != null &&
              (row.venue.longitude != v.longitude ||
                  row.venue.latitude != v.latitude)) {
            throw const FormatException('Matrix venue mismatch');
          }
        }
      }
    } catch (e) {
      error = '$e';
    }
    var requests = 0;
    bool halted = false;
    String? retryAfter;
    final results = <VerifiedVenue>[];
    for (final v in venues) {
      final routes = <VerifiedRoute>[];
      for (var i = 0; i < users.length; i++) {
        final u = users[i];
        VerifiedRoute failure(DirectionsStatus s, String reason) =>
            VerifiedRoute(
              s,
              reason: reason,
              retryAfter: s == DirectionsStatus.rateLimited ? retryAfter : null,
            );
        if (error != null) {
          routes.add(failure(DirectionsStatus.invalidInput, error));
          continue;
        }
        if (!_position([u.position.longitude, u.position.latitude]) ||
            !_position([v.longitude, v.latitude])) {
          routes.add(
            failure(
              DirectionsStatus.invalidInput,
              'Invalid origin or venue coordinates',
            ),
          );
          continue;
        }
        String profile;
        try {
          profile = u.travelMode.orsProfile;
        } on UnsupportedError {
          routes.add(
            failure(
              DirectionsStatus.unsupportedMode,
              'Motorcycle routing unsupported',
            ),
          );
          continue;
        }
        if (halted) {
          routes.add(
            failure(
              DirectionsStatus.rateLimited,
              'Not requested after HTTP 429',
            ),
          );
          continue;
        }
        if (requests >= config.maxRequests) {
          routes.add(
            failure(
              DirectionsStatus.budgetExhausted,
              'Directions request budget exhausted',
            ),
          );
          continue;
        }
        final pair = matrixRows[v.id]?.pairs[i];
        final matrixSeconds =
            pair?.status == PairStatus.success &&
                pair?.seconds != null &&
                pair!.seconds!.isFinite &&
                pair.seconds! >= 0 &&
                pair.seconds != 999999
            ? pair.seconds
            : null;
        requests++;
        final route = await _request(
          u,
          v,
          profile,
          config,
          thresholdSeconds,
          matrixSeconds,
        );
        routes.add(route);
        if (route.status == DirectionsStatus.rateLimited) {
          halted = true;
          retryAfter = route.retryAfter;
        }
      }
      results.add(VerifiedVenue(v, routes, thresholdSeconds));
    }
    watch.stop();
    return DirectionsVerificationResult(users, results, watch.elapsed, error);
  }

  Future<VerifiedRoute> _request(
    UserLocation u,
    ResearchVenue v,
    String profile,
    DirectionsConfig config,
    double? threshold,
    double? matrixSeconds,
  ) async {
    final watch = Stopwatch()..start();
    int? status, code;
    String? retry;
    VerifiedRoute failure(DirectionsStatus s, String reason) => VerifiedRoute(
      s,
      reason: reason,
      httpStatus: status,
      providerCode: code,
      retryAfter: retry,
      requested: true,
      elapsed: watch.elapsed,
      matrixSeconds: matrixSeconds,
    );
    try {
      final response = await (client?.post ?? http.post)(
        Uri.parse('${OrsEndpoints.baseUrl}/directions/$profile/geojson'),
        headers: {
          'Authorization': ApiKeys.ors,
          'Content-Type': 'application/json',
          'Accept': 'application/geo+json',
        },
        body: jsonEncode({
          'coordinates': [
            [u.position.longitude, u.position.latitude],
            [v.longitude, v.latitude],
          ],
          'units': 'm',
          'instructions': false,
        }),
      ).timeout(config.timeout);
      status = response.statusCode;
      retry = response.headers['retry-after'];
      dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {
        if (status == 200) {
          return failure(DirectionsStatus.malformedResponse, 'Invalid JSON');
        }
      }
      if (data is Map && data['error'] is Map && data['error']['code'] is int) {
        code = data['error']['code'];
      }
      if (status == 429) {
        return failure(DirectionsStatus.rateLimited, 'ORS rate limit');
      }
      if (status != 200) {
        return failure(
          code == 2009 || code == 2010
              ? DirectionsStatus.unreachable
              : DirectionsStatus.providerError,
          'ORS HTTP $status',
        );
      }
      try {
        if (data is! Map<String, dynamic> ||
            data['type'] != 'FeatureCollection' ||
            data['features'] is! List) {
          throw const FormatException();
        }
        final features = data['features'] as List;
        if (features.isEmpty) {
          return failure(DirectionsStatus.unreachable, 'No route returned');
        }
        if (features.length != 1) throw const FormatException();
        final feature = features.single;
        if (feature['type'] != 'Feature' ||
            feature['geometry']['type'] != 'LineString') {
          throw const FormatException();
        }
        final coords = feature['geometry']['coordinates'] as List;
        if (coords.length < 2 || coords.any((p) => !_position(p))) {
          throw const FormatException();
        }
        final properties = feature['properties'];
        final summary = properties['summary'];
        final duration = summary['duration'], distance = summary['distance'];
        if (duration is! num ||
            distance is! num ||
            !duration.isFinite ||
            !distance.isFinite ||
            duration < 0 ||
            distance < 0 ||
            duration == 999999) {
          throw const FormatException();
        }
        final waypoints = properties['way_points'];
        if (waypoints != null &&
            (waypoints is! List ||
                waypoints.length != 2 ||
                waypoints[0] != 0 ||
                waypoints[1] != coords.length - 1)) {
          throw const FormatException();
        }
        final start = endpointDistanceMetres(
          u.position.longitude,
          u.position.latitude,
          (coords.first[0] as num).toDouble(),
          (coords.first[1] as num).toDouble(),
        );
        final end = endpointDistanceMetres(
          v.longitude,
          v.latitude,
          (coords.last[0] as num).toDouble(),
          (coords.last[1] as num).toDouble(),
        );
        final snap =
            start <= config.maxStartSnapMetres &&
            end <= config.maxEndSnapMetres;
        final within = threshold == null
            ? null
            : duration <= threshold ||
                  duration - threshold <= config.thresholdToleranceSeconds;
        return VerifiedRoute(
          !snap
              ? DirectionsStatus.excessiveSnapping
              : within == false
              ? DirectionsStatus.thresholdViolation
              : DirectionsStatus.success,
          reason: !snap
              ? 'Endpoint snap limit exceeded'
              : within == false
              ? 'Travel-time threshold exceeded'
              : null,
          httpStatus: status,
          requested: true,
          elapsed: watch.elapsed,
          response: data,
          seconds: duration.toDouble(),
          metres: distance.toDouble(),
          startSnapMetres: start,
          endSnapMetres: end,
          matrixSeconds: matrixSeconds,
          snappingSatisfied: snap,
          thresholdSatisfied: within,
        );
      } catch (_) {
        return failure(
          DirectionsStatus.malformedResponse,
          'Invalid route geometry or measurements',
        );
      }
    } on TimeoutException {
      return failure(DirectionsStatus.timeout, 'Directions request timed out');
    } catch (_) {
      return failure(
        DirectionsStatus.providerError,
        'Directions transport failure',
      );
    }
  }

  static bool _position(dynamic p) =>
      p is List &&
      (p.length == 2 || p.length == 3) &&
      p.every((v) => v is num && v.isFinite) &&
      (p[0] as num).abs() <= 180 &&
      (p[1] as num).abs() <= 90;

  /// Spherical great-circle haversine, mean Earth radius 6,371,008.8 metres.
  static double endpointDistanceMetres(
    double lon1,
    double lat1,
    double lon2,
    double lat2,
  ) {
    final radians = math.pi / 180;
    final dlat = (lat2 - lat1) * radians, dlon = (lon2 - lon1) * radians;
    final a =
        math.pow(math.sin(dlat / 2), 2) +
        math.cos(lat1 * radians) *
            math.cos(lat2 * radians) *
            math.pow(math.sin(dlon / 2), 2);
    return 2 * 6371008.8 * math.asin(math.sqrt(a.clamp(0, 1)));
  }
}
