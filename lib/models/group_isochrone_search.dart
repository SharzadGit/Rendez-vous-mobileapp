import 'road_network_isochrone.dart';
import 'user_location.dart';
import '../services/isochrone_intersection_service.dart';

enum GroupIsochroneStatus { feasibleRegion, noFeasibleRegionFound, failed }

enum GroupIsochroneTermination {
  minimumFeasible,
  precisionReached,
  maximumThresholdInfeasible,
  iterationBudgetExhausted,
  requestBudgetExhausted,
  failure,
}

enum GroupIsochroneFailureCategory {
  invalidInput,
  unsupportedMode,
  providerFailure,
  timeout,
  malformedResponse,
  retrievalEmpty,
  invalidGeometry,
  geometryComputationFailure,
  unsupportedGeometryPrecision,
  numericalNonmonotonicity,
  invalidDependencyResult,
  unexpectedFailure,
}

class GroupIsochroneSearchConfig {
  final Duration minimumThreshold;
  final Duration maximumThreshold;
  final Duration initialStep;
  final Duration timePrecision;
  final int maxIterations;
  final int maxRequests;
  final int concurrency;

  const GroupIsochroneSearchConfig({
    required this.minimumThreshold,
    required this.maximumThreshold,
    required this.initialStep,
    required this.timePrecision,
    this.maxIterations = 32,
    this.maxRequests = 200,
    this.concurrency = 1,
  });
}

class GroupIsochroneFailure {
  final GroupIsochroneFailureCategory category;
  final String message;
  final int? participantIndex;
  final Duration? threshold;
  final Object? cause;
  final int? httpStatusCode;
  final int? providerErrorCode;
  final String? retryAfter;

  const GroupIsochroneFailure(
    this.category,
    this.message, {
    this.participantIndex,
    this.threshold,
    this.cause,
    this.httpStatusCode,
    this.providerErrorCode,
    this.retryAfter,
  });
}

class GroupThresholdEvaluation {
  final Duration threshold;
  final IsochroneIntersectionResult commonRegion;
  bool get feasible => !commonRegion.isEmpty;
  double get thresholdSeconds =>
      threshold.inMicroseconds / Duration.microsecondsPerSecond;

  const GroupThresholdEvaluation(this.threshold, this.commonRegion);
}

/// Wall-clock durations of this run, not experimental performance findings.
/// Retrieval is elapsed batch time (not the sum of concurrent request times).
/// Intersection includes input normalization and observed nesting checks.
class GroupIsochroneTiming {
  final Duration retrieval;
  final Duration intersection;
  final Duration searchOverhead;
  final Duration total;

  const GroupIsochroneTiming({
    required this.retrieval,
    required this.intersection,
    required this.searchOverhead,
    required this.total,
  });
}

/// Intermediate approximate common geographic reachability only. A feasible
/// region establishes neither an eligible venue nor a verified network optimum.
class GroupIsochroneSearchResult {
  final GroupIsochroneStatus status;
  final GroupIsochroneTermination termination;
  final GroupIsochroneFailure? failure;
  final IsochroneIntersectionResult? commonRegion;
  final Duration? selectedThreshold;
  final Duration? lastInfeasibleThreshold;
  final Duration targetPrecision;
  final Duration? achievedBracketWidth;
  final List<UserLocation> participants;
  final List<String?> travelProfiles;
  final List<RoadNetworkIsochrone> selectedIsochrones;
  final List<GroupThresholdEvaluation> evaluations;
  final int apiCalls;
  final int cacheHits;
  final int iterations;
  final GroupIsochroneTiming timing;

  int get participantCount => participants.length;
  int get thresholdEvaluations => evaluations.length;
  Map<String, dynamic>? get geometry => commonRegion?.geometry;
  double? get selectedThresholdSeconds => selectedThreshold == null
      ? null
      : selectedThreshold!.inMicroseconds / Duration.microsecondsPerSecond;

  GroupIsochroneSearchResult({
    required this.status,
    required this.termination,
    required this.failure,
    required this.commonRegion,
    required this.selectedThreshold,
    required this.lastInfeasibleThreshold,
    required this.targetPrecision,
    required this.achievedBracketWidth,
    required List<UserLocation> participants,
    required List<String?> travelProfiles,
    required List<RoadNetworkIsochrone> selectedIsochrones,
    required List<GroupThresholdEvaluation> evaluations,
    required this.apiCalls,
    required this.cacheHits,
    required this.iterations,
    required this.timing,
  }) : participants = List.unmodifiable(participants),
       travelProfiles = List.unmodifiable(travelProfiles),
       selectedIsochrones = List.unmodifiable(selectedIsochrones),
       evaluations = List.unmodifiable(evaluations);
}
