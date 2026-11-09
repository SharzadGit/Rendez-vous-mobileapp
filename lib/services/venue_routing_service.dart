import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';
import '../config/ors_endpoints.dart';
import '../models/research_venue.dart';
import '../models/user_location.dart';

enum PairStatus {
  success,
  unreachable,
  invalidCoordinates,
  unsupportedMode,
  malformedResponse,
  providerFailure,
  timeout,
  budgetExceeded,
  invalidInput,
}

class PairTravelTime {
  final PairStatus status;
  final double? seconds;
  final String? reason;
  const PairTravelTime(this.status, {this.seconds, this.reason});
}

class VenueTravelEvaluation {
  final ResearchVenue venue;
  final List<PairTravelTime> pairs;
  final double? total, mean, maximum, populationStandardDeviation;

  /// Null means absent threshold or incomplete/unreachable matrix results.
  final bool? matrixThresholdVerified;
  bool get fullyReachable =>
      pairs.isNotEmpty && pairs.every((p) => p.status == PairStatus.success);
  VenueTravelEvaluation._(
    this.venue,
    List<PairTravelTime> pairs,
    this.total,
    this.mean,
    this.maximum,
    this.populationStandardDeviation,
    this.matrixThresholdVerified,
  ) : pairs = List.unmodifiable(pairs);
}

class MatrixRequestRecord {
  final String profile;
  final List<int> participantIndices, venueIndices;
  final Duration elapsed;
  final PairStatus status;
  final int? httpStatus;
  final String? retryAfter;
  MatrixRequestRecord(
    this.profile,
    List<int> participants,
    List<int> venues,
    this.elapsed,
    this.status,
    this.httpStatus,
    this.retryAfter,
  ) : participantIndices = List.unmodifiable(participants),
      venueIndices = List.unmodifiable(venues);
}

class VenueRoutingResult {
  final List<UserLocation> participants;
  final List<VenueTravelEvaluation> venues;
  final List<MatrixRequestRecord> requests;
  final String? inputError;
  VenueRoutingResult(
    this.participants,
    this.venues,
    this.requests,
    this.inputError,
  );
  int get actualMatrixRequests => requests.length;
  int get candidateVenuesEvaluated => venues.length;
  int get reachablePairs => venues
      .expand((v) => v.pairs)
      .where((p) => p.status == PairStatus.success)
      .length;
  int get unreachablePairs => venues
      .expand((v) => v.pairs)
      .where((p) => p.status == PairStatus.unreachable)
      .length;
  int get apiFailures =>
      requests.where((r) => r.status != PairStatus.success).length;
  int get cacheHits => 0;
  Duration get requestDuration =>
      requests.fold(Duration.zero, (a, r) => a + r.elapsed);
}

class VenueRoutingConfig {
  final int maxLocations, maxPairs, maxRequests;
  final Duration timeout;
  final double thresholdToleranceSeconds;
  const VenueRoutingConfig({
    this.maxLocations = 50,
    this.maxPairs = 400,
    this.maxRequests = 100,
    this.timeout = const Duration(seconds: 30),
    this.thresholdToleranceSeconds = 1e-6,
  });
}

/// Independent matrix evaluation, not directions-route verification or ranking.
class VenueRoutingService {
  final http.Client? client;
  VenueRoutingService({this.client});
  Future<VenueRoutingResult> evaluate({
    required List<UserLocation> participants,
    required List<ResearchVenue> venues,
    VenueRoutingConfig config = const VenueRoutingConfig(),
    double? thresholdSeconds,
  }) async {
    final users = List<UserLocation>.unmodifiable(participants);
    final candidates = List<ResearchVenue>.unmodifiable(venues);
    final records = <MatrixRequestRecord>[];
    final cells = List.generate(
      candidates.length,
      (_) => List.generate(
        users.length,
        (_) => const PairTravelTime(
          PairStatus.budgetExceeded,
          reason: 'Request budget exhausted',
        ),
      ),
    );
    String? inputError;
    bool valid(double x, double y) =>
        x.isFinite && y.isFinite && x.abs() <= 180 && y.abs() <= 90;
    try {
      if (users.isEmpty ||
          config.maxLocations < 2 ||
          config.maxPairs < 1 ||
          config.maxRequests < 0 ||
          config.timeout <= Duration.zero ||
          !config.thresholdToleranceSeconds.isFinite ||
          config.thresholdToleranceSeconds < 0 ||
          (thresholdSeconds != null &&
              (!thresholdSeconds.isFinite || thresholdSeconds < 0))) {
        throw const FormatException('Invalid evaluation configuration');
      }
      final ids = <String>{};
      for (final v in candidates) {
        if (v.id.trim().isEmpty || !ids.add(v.id)) {
          throw const FormatException('Missing or duplicate venue ID');
        }
      }
    } catch (e) {
      inputError = '$e';
    }
    final groups = <String, List<int>>{};
    for (var i = 0; i < users.length; i++) {
      PairTravelTime? error;
      if (inputError != null) {
        error = PairTravelTime(PairStatus.invalidInput, reason: inputError);
      } else if (!valid(
        users[i].position.longitude,
        users[i].position.latitude,
      )) {
        error = const PairTravelTime(
          PairStatus.invalidCoordinates,
          reason: 'Invalid participant origin',
        );
      } else {
        try {
          groups.putIfAbsent(users[i].travelMode.orsProfile, () => []).add(i);
        } on UnsupportedError {
          error = const PairTravelTime(
            PairStatus.unsupportedMode,
            reason: 'Unsupported motorcycle mode',
          );
        }
      }
      if (error != null) {
        for (final row in cells) {
          row[i] = error;
        }
      }
    }
    final destinations = <int>[];
    for (var j = 0; j < candidates.length; j++) {
      if (!valid(candidates[j].longitude, candidates[j].latitude)) {
        for (var i = 0; i < users.length; i++) {
          cells[j][i] = const PairTravelTime(
            PairStatus.invalidCoordinates,
            reason: 'Invalid venue coordinate',
          );
        }
      } else {
        destinations.add(j);
      }
    }
    for (final group in groups.entries) {
      // At least one destination must fit beside each source chunk.
      final sourceSize = math.min(config.maxLocations - 1, config.maxPairs);
      for (var s = 0; s < group.value.length; s += sourceSize) {
        final src = group.value.sublist(
          s,
          math.min(s + sourceSize, group.value.length),
        );
        final destinationSize = math.min(
          config.maxLocations - src.length,
          config.maxPairs ~/ src.length,
        );
        for (var d = 0; d < destinations.length; d += destinationSize) {
          if (records.length >= config.maxRequests) break;
          final dst = destinations.sublist(
            d,
            math.min(d + destinationSize, destinations.length),
          );
          final watch = Stopwatch()..start();
          var status = PairStatus.success;
          int? httpStatus;
          String? retryAfter;
          String? reason;
          List<List<PairTravelTime>>? parsed;
          try {
            final response = await (client?.post ?? http.post)(
              Uri.parse('${OrsEndpoints.matrix}/${group.key}'),
              headers: {
                'Authorization': ApiKeys.ors,
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode({
                'locations': [
                  for (final i in src)
                    [users[i].position.longitude, users[i].position.latitude],
                  for (final j in dst)
                    [candidates[j].longitude, candidates[j].latitude],
                ],
                'sources': [for (var i = 0; i < src.length; i++) '$i'],
                'destinations': [
                  for (var j = 0; j < dst.length; j++) '${src.length + j}',
                ],
                'metrics': ['duration'],
              }),
            ).timeout(config.timeout);
            httpStatus = response.statusCode;
            retryAfter = response.headers['retry-after'];
            if (httpStatus != 200) {
              status = PairStatus.providerFailure;
              reason = 'ORS HTTP $httpStatus';
            } else {
              try {
                final data = jsonDecode(response.body);
                if (data is! Map || data.containsKey('error')) {
                  throw const FormatException('Invalid matrix envelope');
                }
                final rows = data['durations'];
                if (rows is! List || rows.length != src.length) {
                  throw const FormatException('Wrong source dimension');
                }
                parsed = [];
                for (final row in rows) {
                  if (row is! List || row.length != dst.length) {
                    throw const FormatException('Wrong destination dimension');
                  }
                  final values = <PairTravelTime>[];
                  for (final value in row) {
                    if (value == null) {
                      values.add(
                        const PairTravelTime(
                          PairStatus.unreachable,
                          reason: 'ORS returned null',
                        ),
                      );
                    } else if (value is! num ||
                        !value.isFinite ||
                        value < 0 ||
                        value == 999999) {
                      throw const FormatException(
                        'Invalid duration or legacy sentinel',
                      );
                    } else {
                      values.add(
                        PairTravelTime(
                          PairStatus.success,
                          seconds: value.toDouble(),
                        ),
                      );
                    }
                  }
                  parsed.add(values);
                }
              } catch (_) {
                status = PairStatus.malformedResponse;
                reason = 'Invalid matrix response';
                parsed = null;
              }
            }
          } on TimeoutException {
            status = PairStatus.timeout;
            reason = 'Matrix request timed out';
          } catch (_) {
            status = PairStatus.providerFailure;
            reason = 'Matrix transport failure';
          }
          watch.stop();
          records.add(
            MatrixRequestRecord(
              group.key,
              src,
              dst,
              watch.elapsed,
              status,
              httpStatus,
              retryAfter,
            ),
          );
          for (var i = 0; i < src.length; i++) {
            for (var j = 0; j < dst.length; j++) {
              cells[dst[j]][src[i]] = status == PairStatus.success
                  ? parsed![i][j]
                  : PairTravelTime(status, reason: reason);
            }
          }
        }
      }
    }
    final results = <VenueTravelEvaluation>[];
    for (var j = 0; j < candidates.length; j++) {
      final row = cells[j];
      double? total, mean, maximum, sd;
      bool? verified;
      if (row.isNotEmpty && row.every((p) => p.status == PairStatus.success)) {
        final values = row.map((p) => p.seconds!).toList();
        total = values.fold(0.0, (a, b) => a! + b);
        maximum = values.reduce(math.max);
        mean = total! / values.length;
        // Scaled population variance avoids squaring large raw seconds.
        final scale = maximum;
        sd = scale == 0
            ? 0
            : scale *
                  math.sqrt(
                    values.fold<double>(
                          0,
                          (a, v) => a + math.pow(v / scale - mean! / scale, 2),
                        ) /
                        values.length,
                  );
        if (!total.isFinite || !mean.isFinite || !sd.isFinite) {
          total = null;
          mean = null;
          maximum = null;
          sd = null;
          for (var i = 0; i < row.length; i++) {
            row[i] = const PairTravelTime(
              PairStatus.malformedResponse,
              reason: 'Aggregate overflow',
            );
          }
        } else if (thresholdSeconds != null) {
          verified = values.every(
            (v) =>
                v <= thresholdSeconds ||
                v - thresholdSeconds <= config.thresholdToleranceSeconds,
          );
        }
      }
      results.add(
        VenueTravelEvaluation._(
          candidates[j],
          row,
          total,
          mean,
          maximum,
          sd,
          verified,
        ),
      );
    }
    return VenueRoutingResult(
      users,
      List.unmodifiable(results),
      List.unmodifiable(records),
      inputError,
    );
  }
}
