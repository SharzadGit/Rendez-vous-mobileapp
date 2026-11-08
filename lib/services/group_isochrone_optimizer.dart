import 'dart:async';

import '../config/ors_endpoints.dart';
import '../models/group_isochrone_search.dart';
import '../models/road_network_isochrone.dart';
import '../models/user_location.dart';
import '../repositories/isochrone_repository.dart';
import 'isochrone_intersection_service.dart';

typedef _Key = (double, double, String, int, String, String, String);

/// Bounded search for an approximate common region; not venue selection.
/// Each invocation owns its cache/state, so this service may be reused safely.
class GroupIsochroneOptimizer {
  final IsochroneRepository repository;
  final IsochroneIntersectionService intersectionService;

  GroupIsochroneOptimizer({
    IsochroneRepository? repository,
    IsochroneIntersectionService? intersectionService,
  }) : repository = repository ?? IsochroneRepository(),
       intersectionService =
           intersectionService ?? IsochroneIntersectionService();

  Future<GroupIsochroneSearchResult> optimize({
    required List<UserLocation> participants,
    required GroupIsochroneSearchConfig config,
  }) => _Search(repository, intersectionService, participants, config).run();
}

class _Contour {
  final RoadNetworkIsochrone isochrone;
  final BigInt area;
  const _Contour(this.isochrone, this.area);
}

class _Abort implements Exception {
  final GroupIsochroneFailure failure;
  const _Abort(this.failure);
}

class _Budget implements Exception {
  final GroupIsochroneTermination reason;
  const _Budget(this.reason);
}

class _Search {
  final IsochroneRepository repository;
  final IsochroneIntersectionService intersector;
  final List<UserLocation> users;
  final GroupIsochroneSearchConfig config;
  final cache = <_Key, _Contour>{};
  final evaluations = <GroupThresholdEvaluation>[];
  final profiles = <String?>[];
  final total = Stopwatch();
  Duration retrievalTime = Duration.zero;
  Duration intersectionTime = Duration.zero;
  int apiCalls = 0, cacheHits = 0, iterations = 0;
  Duration? low, high;
  IsochroneIntersectionResult? best;
  List<RoadNetworkIsochrone> bestContours = [];

  _Search(
    this.repository,
    this.intersector,
    List<UserLocation> users,
    this.config,
  ) : users = List.unmodifiable(users);

  Future<GroupIsochroneSearchResult> run() async {
    total.start();
    try {
      _validate();
      var threshold = config.minimumThreshold;
      var step = config.initialStep.inMicroseconds;
      while (true) {
        final (region, contours) = await _evaluate(threshold);
        if (!region.isEmpty) {
          high = threshold;
          best = region;
          bestContours = contours;
          break;
        }
        low = threshold;
        if (threshold == config.maximumThreshold) {
          return _finish(GroupIsochroneTermination.maximumThresholdInfeasible);
        }
        final remaining = (config.maximumThreshold - threshold).inMicroseconds;
        final delta = step < remaining ? step : remaining;
        threshold += Duration(microseconds: delta);
        // Saturating growth avoids overflow and never overshoots the maximum.
        final range =
            (config.maximumThreshold - config.minimumThreshold).inMicroseconds;
        step = step >= range ~/ 2 ? range : step * 2;
      }
      if (low == null) {
        return _finish(GroupIsochroneTermination.minimumFeasible);
      }
      while (high! - low! > config.timePrecision) {
        final mid =
            low! + Duration(microseconds: (high! - low!).inMicroseconds ~/ 2);
        final (region, contours) = await _evaluate(mid);
        if (region.isEmpty) {
          low = mid;
        } else {
          high = mid;
          best = region;
          bestContours = contours;
        }
      }
      return _finish(GroupIsochroneTermination.precisionReached);
    } on _Budget catch (budget) {
      return _finish(budget.reason);
    } on _Abort catch (abort) {
      return _finish(GroupIsochroneTermination.failure, abort.failure);
    } catch (error) {
      return _finish(
        GroupIsochroneTermination.failure,
        GroupIsochroneFailure(
          GroupIsochroneFailureCategory.unexpectedFailure,
          'Unexpected search failure: $error',
          cause: error,
        ),
      );
    }
  }

  void _validate() {
    if (users.length < 2 ||
        users.length > 20 ||
        config.minimumThreshold <= Duration.zero ||
        config.maximumThreshold < config.minimumThreshold ||
        config.initialStep <= Duration.zero ||
        config.timePrecision <= Duration.zero ||
        config.maxIterations < 0 ||
        config.maxRequests < 0 ||
        config.concurrency < 1 ||
        config.concurrency > 20 ||
        [
          config.maximumThreshold,
          config.initialStep,
          config.timePrecision,
        ].any((t) => t.inMicroseconds > 9007199254740991)) {
      _abort(
        GroupIsochroneFailureCategory.invalidInput,
        'Invalid group or search configuration.',
      );
    }
    for (var i = 0; i < users.length; i++) {
      final p = users[i].position;
      if (!p.latitude.isFinite ||
          !p.longitude.isFinite ||
          p.latitude.abs() > 90 ||
          p.longitude.abs() > 180) {
        _abort(
          GroupIsochroneFailureCategory.invalidInput,
          'Invalid WGS84 origin.',
          index: i,
        );
      }
      try {
        profiles.add(users[i].travelMode.orsProfile);
      } on UnsupportedError {
        profiles.add(null);
        _abort(
          GroupIsochroneFailureCategory.unsupportedMode,
          'Motorcycle mode is unsupported.',
          index: i,
        );
      }
    }
  }

  _Key _key(int index, Duration threshold) => (
    users[index].position.longitude,
    users[index].position.latitude,
    profiles[index]!,
    threshold.inMicroseconds,
    OrsEndpoints.isochrones,
    'time',
    'start',
  );

  Future<(IsochroneIntersectionResult, List<RoadNetworkIsochrone>)> _evaluate(
    Duration threshold,
  ) async {
    if (iterations >= config.maxIterations) {
      throw const _Budget(GroupIsochroneTermination.iterationBudgetExhausted);
    }
    final keys = [for (var i = 0; i < users.length; i++) _key(i, threshold)];
    final missing = <_Key, int>{};
    for (var i = 0; i < keys.length; i++) {
      if (!cache.containsKey(keys[i])) missing.putIfAbsent(keys[i], () => i);
    }
    // Reserve the complete uncached batch. Never start a knowingly partial
    // threshold or exceed the budget even with concurrent workers.
    if (missing.length > config.maxRequests - apiCalls) {
      throw const _Budget(GroupIsochroneTermination.requestBudgetExhausted);
    }
    iterations++;
    final fetched = <_Key, RoadNetworkIsochrone>{};
    final requests = missing.entries.toList();
    var next = 0;
    _Abort? firstFailure;
    final retrieval = Stopwatch()..start();
    try {
      Future<void> worker() async {
        while (firstFailure == null && next < requests.length) {
          final item = requests[next++];
          final user = users[item.value];
          apiCalls++;
          try {
            final iso = await repository.getIsochrone(
              origin: user.position,
              travelMode: user.travelMode,
              travelTime: threshold,
            );
            if (iso.origin.latitude != user.position.latitude ||
                iso.origin.longitude != user.position.longitude ||
                iso.travelMode != user.travelMode ||
                iso.travelTime != threshold) {
              _abort(
                GroupIsochroneFailureCategory.invalidDependencyResult,
                'Retrieved contour provenance does not match the request.',
                index: item.value,
                threshold: threshold,
              );
            }
            fetched[item.key] = iso;
          } catch (error) {
            firstFailure ??= error is _Abort
                ? error
                : _Abort(_failure(error, item.value, threshold));
          }
        }
      }

      // Workers stop launching new requests after failure. All in-flight work
      // is drained before returning, and every started call remains counted.
      await Future.wait(
        List.generate(
          requests.length < config.concurrency
              ? requests.length
              : config.concurrency,
          (_) => worker(),
        ),
      );
      if (firstFailure != null) throw firstFailure!;
    } finally {
      retrievalTime += retrieval.elapsed;
    }
    // Hits count resolved participant lookups reusing a prior successful result
    // or one coalesced same-batch origin/profile/threshold request.
    cacheHits += keys.length - missing.length;
    final intersection = Stopwatch()..start();
    try {
      for (final entry in fetched.entries) {
        final index = missing[entry.key]!;
        final iso = entry.value;
        final normalized = _intersect([iso, iso], threshold, index);
        final area = _area(normalized);
        if (normalized.isEmpty || area <= BigInt.zero) {
          _abort(
            GroupIsochroneFailureCategory.invalidGeometry,
            'Single-origin normalization produced no positive area.',
            index: index,
            threshold: threshold,
          );
        }
        final contour = _Contour(iso, area);
        // Check both observed neighbors: binary refinement inserts contours
        // between previously sampled thresholds. Do not assume provider nesting.
        final history =
            cache.entries
                .where(
                  (e) =>
                      e.key.$1 == entry.key.$1 &&
                      e.key.$2 == entry.key.$2 &&
                      e.key.$3 == entry.key.$3,
                )
                .toList()
              ..sort((a, b) => a.key.$4.compareTo(b.key.$4));
        _Contour? below, above;
        for (final previous in history) {
          if (previous.key.$4 < entry.key.$4) below = previous.value;
          if (previous.key.$4 > entry.key.$4) {
            above = previous.value;
            break;
          }
        }
        void check(_Contour smaller, _Contour larger) {
          final overlap = _intersect(
            [smaller.isochrone, larger.isochrone],
            threshold,
            index,
          );
          if (_area(overlap) != smaller.area) {
            _abort(
              GroupIsochroneFailureCategory.numericalNonmonotonicity,
              'Observed contours are not nested at the geometry grid; '
              'provider variation or numerical effects invalidate threshold refinement.',
              index: index,
              threshold: threshold,
            );
          }
        }

        if (below != null) check(below, contour);
        if (above != null) check(contour, above);
        cache[entry.key] = contour;
      }
      final ordered = [for (final key in keys) cache[key]!.isochrone];
      final region = _intersect(ordered, threshold);
      if (!region.isEmpty && _area(region) <= BigInt.zero) {
        _abort(
          GroupIsochroneFailureCategory.invalidGeometry,
          'Intersection has no positive area.',
          threshold: threshold,
        );
      }
      if (evaluations.any(
        (e) =>
            (e.feasible && e.threshold < threshold && region.isEmpty) ||
            (!e.feasible && e.threshold > threshold && !region.isEmpty),
      )) {
        _abort(
          GroupIsochroneFailureCategory.numericalNonmonotonicity,
          'Observed common-region feasibility is nonmonotonic.',
          threshold: threshold,
        );
      }
      evaluations.add(GroupThresholdEvaluation(threshold, region));
      return (region, List<RoadNetworkIsochrone>.unmodifiable(ordered));
    } on _Abort {
      rethrow;
    } catch (error) {
      throw _Abort(_failure(error, null, threshold));
    } finally {
      intersectionTime += intersection.elapsed;
    }
  }

  // Exact signed shoelace on the existing service's declared grid. Used only
  // for zero-area/nesting audits, never as a replacement for Boolean clipping.
  BigInt _area(IsochroneIntersectionResult result) {
    if (result.isEmpty) return BigInt.zero;
    final geometry = result.geometry!;
    final polygons = geometry['type'] == 'Polygon'
        ? [geometry['coordinates']]
        : geometry['coordinates'] as List;
    var totalArea = BigInt.zero;
    for (final polygon in polygons) {
      final rings = polygon as List;
      for (var r = 0; r < rings.length; r++) {
        final ring = rings[r] as List;
        var twiceArea = BigInt.zero;
        for (var i = 0; i < ring.length - 1; i++) {
          final a = ring[i], b = ring[i + 1];
          final ax = BigInt.from(((a[0] as num) * 1e7).round());
          final ay = BigInt.from(((a[1] as num) * 1e7).round());
          final bx = BigInt.from(((b[0] as num) * 1e7).round());
          final by = BigInt.from(((b[1] as num) * 1e7).round());
          twiceArea += ax * by - ay * bx;
        }
        totalArea += r == 0 ? twiceArea.abs() : -twiceArea.abs();
      }
    }
    return totalArea;
  }

  GroupIsochroneFailure _failure(Object error, int? index, Duration threshold) {
    final GroupIsochroneFailureCategory category;
    if (error is IsochroneException) {
      category = switch (error.kind) {
        IsochroneFailure.invalidInput =>
          GroupIsochroneFailureCategory.invalidInput,
        IsochroneFailure.unsupportedMode =>
          GroupIsochroneFailureCategory.unsupportedMode,
        IsochroneFailure.timeout => GroupIsochroneFailureCategory.timeout,
        IsochroneFailure.malformedResponse =>
          GroupIsochroneFailureCategory.malformedResponse,
        IsochroneFailure.emptyResult =>
          GroupIsochroneFailureCategory.retrievalEmpty,
        IsochroneFailure.requestFailed =>
          GroupIsochroneFailureCategory.providerFailure,
      };
    } else if (error is IsochroneIntersectionException) {
      index ??= error.participantIndex;
      category = switch (error.kind) {
        IntersectionFailure.invalidInput =>
          GroupIsochroneFailureCategory.invalidGeometry,
        IntersectionFailure.unsupportedPrecision =>
          GroupIsochroneFailureCategory.unsupportedGeometryPrecision,
        IntersectionFailure.computationFailed =>
          GroupIsochroneFailureCategory.geometryComputationFailure,
      };
    } else if (error is TimeoutException) {
      category = GroupIsochroneFailureCategory.timeout;
    } else {
      category = GroupIsochroneFailureCategory.unexpectedFailure;
    }
    return GroupIsochroneFailure(
      category,
      error.toString(),
      participantIndex: index,
      threshold: threshold,
      cause: error,
      httpStatusCode: error is IsochroneException ? error.statusCode : null,
      providerErrorCode: error is IsochroneException
          ? error.providerCode
          : null,
      retryAfter: error is IsochroneException ? error.retryAfter : null,
    );
  }

  IsochroneIntersectionResult _intersect(
    List<RoadNetworkIsochrone> contours,
    Duration threshold, [
    int? index,
  ]) {
    try {
      final result = intersector.intersect(contours);
      if (result.participantCount != contours.length) {
        _abort(
          GroupIsochroneFailureCategory.invalidDependencyResult,
          'Intersection participant count mismatch.',
          threshold: threshold,
          index: index,
        );
      }
      return result;
    } on _Abort {
      rethrow;
    } catch (error) {
      throw _Abort(_failure(error, index, threshold));
    }
  }

  Never _abort(
    GroupIsochroneFailureCategory category,
    String message, {
    int? index,
    Duration? threshold,
  }) => throw _Abort(
    GroupIsochroneFailure(
      category,
      message,
      participantIndex: index,
      threshold: threshold,
    ),
  );

  GroupIsochroneSearchResult _finish(
    GroupIsochroneTermination reason, [
    GroupIsochroneFailure? failure,
  ]) {
    total.stop();
    final success = failure == null && best != null;
    return GroupIsochroneSearchResult(
      status: failure != null
          ? GroupIsochroneStatus.failed
          : success
          ? GroupIsochroneStatus.feasibleRegion
          : GroupIsochroneStatus.noFeasibleRegionFound,
      termination: reason,
      failure: failure,
      commonRegion: success ? best : null,
      selectedThreshold: success ? high : null,
      lastInfeasibleThreshold: low,
      targetPrecision: config.timePrecision,
      achievedBracketWidth: success && low != null ? high! - low! : null,
      participants: users,
      travelProfiles: [
        ...profiles,
        ...List<String?>.filled(users.length - profiles.length, null),
      ],
      selectedIsochrones: success ? bestContours : const [],
      evaluations: evaluations,
      apiCalls: apiCalls,
      cacheHits: cacheHits,
      iterations: iterations,
      timing: GroupIsochroneTiming(
        retrieval: retrievalTime,
        intersection: intersectionTime,
        searchOverhead: total.elapsed - retrievalTime - intersectionTime,
        total: total.elapsed,
      ),
    );
  }
}
