# Shortlisted venue directions verification

## API

```dart
DirectionsVerificationService({http.Client? client});
Future<DirectionsVerificationResult> verify({
  required List<UserLocation> participants,
  required List<ResearchVenue> shortlist,
  VenueRoutingResult? matrix,
  double? thresholdSeconds,
  DirectionsConfig config = const DirectionsConfig(),
});
```

This is an independent service. It neither selects nor ranks venues and is not
connected to the UI or existing optimization algorithms. The caller must provide
an explicit shortlist; maxVenues defaults to 5 and rejects larger lists rather
than automatically processing an entire dataset. Duplicate/missing venue IDs and
invalid configuration produce inputError without requests. Coordinate failures
and unsupported motorcycle modes remain explicit per-pair results. Participant
and venue input order is preserved, with an immutable input snapshot and outputs.
Empty shortlists cause no requests; an empty participant group is invalid.

## Verified official contract

Consulted official ORS sources on 2026-11-09 (documentation reads only):

- https://github.com/GIScience/openrouteservice/blob/main/docs/api-reference/endpoints/directions/requests-and-return-types.md
- https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/requests/routing/RouteRequest.java
- https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/responses/routing/geojson/GeoJSONRouteResponse.java
- https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/responses/routing/geojson/GeoJSONIndividualRouteResponse.java
- https://github.com/GIScience/openrouteservice/blob/main/ors-engine/src/main/java/org/heigit/ors/routing/RoutingErrorCodes.java

The service uses the existing centralized HeiGIT base URL and profile mapping:
POST `https://api.heigit.org/openrouteservice/v2/directions/{profile}/geojson`.
Authorization is unchanged. Body:

```json
{
  "coordinates": [[77.0, 12.0], [78.0, 13.0]],
  "units": "m",
  "instructions": false
}
```

These coordinates illustrate schema only, not empirical routes. Origin is first,
venue second. There is one request per participant/venue pair, sequentially in
venue-major, participant-minor order. There are no alternative routes requested,
retries, caching, or automatic parallel calls. Defaults: maxRequests=100,
timeout=30 seconds. These are local safeguards, not verified hosted quotas.
HTTP 429 halts further scheduling for the entire invocation and preserves raw
Retry-After on affected and unrequested records. No sleeping/retrying occurs;
external orchestration must respect Retry-After and coordinate quotas across runs.
Other failures remain recorded and subsequent pairs continue within budget.
Timeout stops waiting but does not cancel underlying transport or its quota cost.
Injected HTTP clients are caller-owned. No valid API key is needed in MockClient tests.

## Route validation and outcomes

A successful response must be a FeatureCollection containing exactly one Feature
with a LineString of at least two finite WGS84 coordinates (2D or 3D). Every point
is validated. Summary duration must be finite nonnegative seconds and distance
finite nonnegative metres. The legacy duration sentinel 999999 is rejected.
Optional way_points must contain exactly the first and last geometry indices for
the two requested locations. Missing geometry, wrong geometry types/dimensions,
invalid summaries and ambiguous multiple routes are malformedResponse. An empty
feature collection or official route/point-not-found codes 2009/2010 is unreachable.
HTTP 429 is rateLimited; other HTTP/transport failures are providerError. HTTP and
provider codes are retained without copying error body text into diagnostics.

A validated response is deeply frozen and preserved in full, including route
geometry, feature properties, warnings, and provider metadata. routedStart and
routedEnd expose the first and last LineString coordinates. These are inferred
routed endpoints, not a separate assertion of the provider's internal snap state.
Distances to requested endpoints use spherical great-circle haversine with mean
Earth radius 6,371,008.8 m, clamping the haversine term to [0,1]. Elevation is ignored.
This geodesic approximation is not an ellipsoidal survey measurement and can differ
by roughly 0.5% from an ellipsoidal distance; choose snap limits accordingly.
Default start/end snap limits are independently configurable at 100 m each.
No artificial route geometry or penalty duration is substituted for failures.

snappingSatisfied and thresholdSatisfied are retained independently. Excessive
snapping takes primary status precedence over thresholdViolation when both fail.
With no threshold, thresholdSatisfied is null. With a finite nonnegative threshold,
all successful routes must meet it within an absolute seconds tolerance (default
1e-6). directionsThresholdVerified is null without a threshold, otherwise true
only if every participant route succeeds with both constraints satisfied. Missing,
failed, budget-exhausted and rate-limited routes make it false, not unknown success.
A successful route without a threshold means geometry/summary/snap checks passed.

## Matrix comparison and telemetry

Optional matrix results must match participant IDs, order, coordinates, and modes;
matching venue IDs must also match venue coordinates. Provenance mismatch rejects
the invocation before requests. Matrix collections may contain additional venues;
missing shortlist rows simply have no comparison. Only successful finite,
nonnegative non-sentinel matrix cells are compared. Failed matrix cells never
prevent independent directions retrieval. Neither measurement overwrites the other.
absoluteDiscrepancySeconds = abs(directionsSeconds - matrixSeconds).
percentageDiscrepancy = 100 * absoluteDiscrepancySeconds / matrixSeconds; it is null
for a zero matrix denominator, even when both measurements are zero. Differences
are descriptive; no automatic agreement cutoff or ranking is imposed.

Per-pair records expose status/reason, requested flag, HTTP/provider status,
Retry-After, elapsed request time, both durations/discrepancies, distance and snap
distances. ActualRequests counts attempted HTTP calls; successfulRoutes counts
pairs passing route/snap/threshold criteria; failedRoutes includes unrequested
and invalid pairs. Runtime measures the whole invocation, including processing.
Timings are local telemetry, not experimental performance results.

## Evidence and limitations

Offline tests cover all profiles, mixed groups of 3/5/10/20 participants, two
venues, direction/order, geometry/summaries, known haversine distances, snap and
threshold failures, matrix disagreement and provenance, unreachable/provider
errors, 429 scheduling stop, timeout, budgets, malformed responses, unsupported
modes, oversized and empty shortlists. Fixtures are synthetic and labeled.

A provider route does not establish actual physical entrance accessibility,
opening hours, permission, safety, or real-time road conditions. Geometry validation
does not independently audit every road edge, route legality or provider correctness.
Live HeiGIT behavior, real ORS responses/quotas and empirical Bengaluru experiments
remain unverified. Provider data can change between matrix and directions calls.
Archive inputs, configuration, frozen responses and dataset versions for later
reproducibility. No venue ranking, min-sum/min-max optimization, or UI integration
is implemented. No live ORS requests or empirical results were produced.
