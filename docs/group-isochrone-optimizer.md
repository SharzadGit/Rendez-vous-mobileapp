# Group isochrone threshold search: intermediate common reachability

**Scientific scope:** a nonempty intersection establishes approximate common
geographic reachability at the provider/grid resolution. It establishes neither
an eligible venue nor an exactly verified road-network min-max solution.
Threshold selection here is not a venue optimization or a comparison against
network min-sum/min-max baselines. Do not interpret the selected time as a proven
network optimum. No live ORS requests or experimental performance results were
used in this implementation.

## Public API

```dart
GroupIsochroneOptimizer({
  IsochroneRepository? repository,
  IsochroneIntersectionService? intersectionService,
});

Future<GroupIsochroneSearchResult> optimize({
  required List<UserLocation> participants,
  required GroupIsochroneSearchConfig config,
});
```

The existing single-origin repository and offline Boolean intersection service
are injected as dependencies or used directly by default. Subclasses can provide
fully offline deterministic test doubles. The service creates independent state
and cache for each invocation. Participant inputs are captured in an unmodifiable
list; neither this service nor the cache reorders or deduplicates participant rows.
The two existing optimization algorithms and the UI remain unchanged. In
particular, the older `IsochroneService` is not replaced or relabeled here.

`GroupIsochroneSearchConfig` requires `minimumThreshold`, `maximumThreshold`,
`initialStep`, and `timePrecision` as positive `Duration`s, with maximum >= minimum.
The maximum/step/precision microsecond values must fit JavaScript's safe integer
range. Optional `maxIterations` (32), `maxRequests` (200), and `concurrency` (1)
control per-search costs. Zero iteration or request budgets are valid and stop
without work; negative budgets are invalid. Concurrency must be 1–20. These are
local budgets, not a claim about the limits of a hosted API plan. The injected
repository supplies its own per-request timeout (default 30 seconds).

Origins must be finite WGS84 coordinates and participants must number 2–20.
Driving, cycling (bicycle), and walking reuse `TravelMode.orsProfile` exactly.
Motorcycle/two-wheeler is rejected before any request. Each unique query calls
`getIsochrone(origin: ..., travelMode: ..., travelTime: tau)` once. It therefore
uses the existing POST `/v2/isochrones/{profile}` request with one origin,
`location_type=start`, `range_type=time`, seconds, and `[longitude, latitude]`.
No batch-origin capacity is assumed.

## Algorithm

All quantities below are integer microseconds until encoded as seconds by the
repository. Thus midpoint selection and termination never depend on floating
minute/second conversions.

```text
validate inputs/configuration
low = unknown; high = unknown; best = none
threshold = minimum; step = initialStep
repeat:
    if no iteration remains: stop with iteration-budget reason
    plan all unique uncached participant queries at threshold
    if the complete plan exceeds remaining request budget: stop before any call
    count one attempted iteration
    fetch with at most concurrency workers, coalescing identical queries
    on error: stop launching new work; await in-flight repository futures; fail
    restore every participant contour to original input order
    validate provenance and normalize each new contour with the existing service
    check observed lower/new/upper contour nesting at the declared grid
    intersect all participant contours and record this completed evaluation
    if feasible: high = threshold; best = actual region and ordered contours; break
    low = threshold
    if threshold == maximum: return no-feasible-region-found (maximum tested)
    threshold = min(maximum, threshold + step)
    double step with saturation to avoid overflow
if no low exists: return minimum-feasible (no lower transition bracket)
while high - low > timePrecision:
    evaluate floor((low + high)/2), with the same budgeting/checks as above
    if empty: low = midpoint
    else: high = midpoint; best = actual region and ordered contours
return best with precision-reached reason
```

The step grows as increments from the previous threshold, not as an absolute
multiple of zero. For example, minimum=2s and step=2s evaluates 2, 4, 8, 16…,
clamped to the maximum. Tests use two squares with half-width tau/1000 degrees
and origins .02 degrees apart: tau=10s has boundary-only contact and is infeasible;
refinement to 1s yields the observed bracket (10s,11s]. This is analytic test
geometry, not an observed road-network result.

A budget stop before any feasible sample returns `noFeasibleRegionFound` with the
specific exhausted budget. It is **not evidence of global infeasibility**. If a
feasible sample already exists, a budget stop retains it but reports the actual
bracket width, which may exceed requested precision. Minimum-feasible has no
infeasible lower endpoint, so achieved bracket width is null. Exhausting the
maximum without overlap refers only to the configured search domain and sampled
provider geometries. No search can resolve feasibility below the minimum or above
the maximum.

## Cache, concurrency and cost

The invocation-local key contains exact longitude, latitude, profile, threshold
microseconds, endpoint/version, range type and location type. All currently
variable/explicit geometric request parameters are represented. Repository
configuration and its provider are fixed for one invocation; if the request API
later gains options (smoothing, avoidance, etc.), extend the cache key accordingly.
No credential values are stored in the key. No cache persists across searches.
Failed retrievals are not inserted into the successful contour cache.

`apiCalls` counts started repository calls, including failed/timed-out attempts.
With the default repository (one POST, no retries), this equals HTTP attempts.
An injected repository that performs its own retries must supply separate
transport accounting; internal retries cannot be observed by this service.
`cacheHits` counts resolved participant lookups saved by successful cache reuse or
same-batch coalescing. A failed retrieval batch does not count unresolved lookups
as hits. Most thresholds are distinct; in this search, reuse primarily benefits
co-located participants using the same profile, not unrelated origins or times.
Normalization and nesting audits use stored contours, never extra API calls.

Before evaluating a threshold, reserve capacity for its entire set of cache
misses. A budget insufficient for a complete threshold causes no partial requests
for that threshold. Workers stop scheduling new calls after the first observed
failure and await all already-started repository futures. Their costs remain
counted. As documented for the retrieval layer, timeout bounds waiting but does
not cancel the underlying HTTP transport. Concurrent failures report the first
observed failure; its identity can depend on completion order. There are no
automatic retries.

For N participants and E completed thresholds, at most N*E service calls are
needed without cache reuse, bounded by `maxRequests`; a failed threshold can also
consume counted calls without completing an evaluation. At most `maxIterations`
thresholds are attempted. The expansion is logarithmic in range/step, and binary
refinement is logarithmic in bracket/precision, until budgets or failures stop it.
Geometry cost is additional: each uncached contour is normalized, checked against
at most two observed neighbors, and included in one group intersection per
threshold. Complexity depends on vertex count, topology and engine behavior, not
just participant count. History lookup scans the cache and sorts matching series;
its bookkeeping can be quadratic in cached queries, with additional sorting.
The cache stores up to the request-budget number of full contours; evaluation
history also retains common-region geometries. Large contours or budgets can
therefore be expensive in CPU and memory. This implementation favors auditability
over reducing geometric checks and does not make performance guarantees.

Concurrency is per invocation, **not** a global/per-minute quota limiter. Concurrent
searches do not share rate limits. Even concurrency=1 can exceed a hosted quota.
Verify plan-specific range limits, call quotas and road-network metadata before
live use; provide external pacing/orchestration and respect `Retry-After` on a
reported quota failure. No hosted numeric cap or data-version stability is assumed.

## Numerical checks and failures

The existing 1e-7-degree grid, one-degree extent, 2D geometry and minimum input-ring
area contract remains mandatory; see `isochrone-intersection.md`. Off-grid,
invalid, too-small or overly wide geometries fail, not fall back to circles,
bounding boxes, repaired polygons, or an empty-success result.

For each origin/profile series, compare a new contour with the nearest observed
smaller and larger thresholds. Use the existing Boolean intersection engine and
exact BigInt shoelace area on its declared grid to check that the smaller region
retains all positive area in its intersection with the larger. The area check is
an audit of an actual polygon intersection, never an overlap substitute. The
normalization step unions a contour's features via the existing service, so holes
and overlapping feature areas are not double-counted. Also check observed group
feasibility for contradictions. A nesting/feasibility contradiction returns
`numericalNonmonotonicity`; this may reflect provider variation, contour smoothing,
or finite-precision artifacts. The service does not guess the underlying cause.

These checks cover **observed** contours at grid resolution. They do not prove
nesting between all unsampled thresholds, stable provider/network data, or exact
containment below the grid. Clipping rounds newly computed vertices; near-degenerate
shapes can still be order-sensitive or lose sub-grid area. Binary refinement is
conditional on sampled nesting and the provider/geometry assumptions. Failure
clears the candidate geometry and selected threshold, even if an earlier sample
was feasible; previous evaluations remain available for diagnosis.

Failure categories distinguish invalid input, unsupported mode, provider failure,
timeout, malformed response, empty retrieval, invalid geometry, unsupported
geometry precision, geometry computation failure, observed nonmonotonicity,
invalid dependency provenance/counts, and unexpected failures. An empty retrieved
FeatureCollection is a `retrievalEmpty` failure, not a valid zero-area group
intersection. Error details include participant index and threshold where known,
original cause, HTTP status, provider code, and `Retry-After` where supplied.

## Result and timing semantics

`GroupIsochroneSearchResult` contains status, termination, optional failure,
actual `commonRegion` / GeoJSON `geometry`, selected threshold (also exposed as
`selectedThresholdSeconds`), last observed infeasible threshold, requested
`targetPrecision`, and actual `achievedBracketWidth`. It preserves participant
rows, profiles, and the selected threshold's ordered original isochrones. Profiles
not resolved during failed preflight validation are null. Region geometry and
returned lists are immutable. Evaluation history records each completed threshold
and its actual intersection result. `iterations` includes attempted thresholds
that fail after calls start; `thresholdEvaluations` counts completed evaluations.

Timing uses monotonic Stopwatches: retrieval is wall time awaiting a complete
batch (not the sum of overlapping requests); intersection includes normalization,
nesting audits and the group intersection; `searchOverhead` is the remaining local
bookkeeping; `total` is their sum. These are telemetry from a particular run,
including injected test dependencies if used. They are not published benchmark
results or evidence of algorithmic speed on real Bengaluru road data.

## Offline verification and next integration boundary

Tests use the actual retrieval method with MockClient and manually defined,
analytically understood polygons, plus injectable repository/intersection doubles.
They require no API key or real requests. Coverage includes 2,3,5,10,20 participants,
expansion/refinement, subsecond units, initial feasibility, bounded exhaustion,
co-located cache reuse, mixed profiles, holes/disconnected components, concurrency,
failure draining, bad provenance, invalid input/geometry, provider/timeout errors,
and nonnested contours during both expansion and refinement.

```sh
source /workspace/.toolchains/flutter-env.sh
flutter test --no-pub test/group_isochrone_optimizer_test.dart \
  test/isochrone_intersection_service_test.dart \
  test/isochrone_repository_test.dart test/routing_repository_test.dart
flutter test --no-pub --platform chrome test/group_isochrone_optimizer_test.dart
flutter analyze --no-pub
git diff --check
```

Recorded verification: all 177 relevant VM tests passed (51 new group-search
tests plus 126 existing tests), and all 51 group-search tests passed in Chromium.
Analysis reports no errors or new findings; the existing 3 warnings and 9
informational findings remain. Whitespace checks include all new files.

The service is suitable for beginning a separate venue-selection integration step
under these explicit assumptions. It is not integrated into the UI, does not
retrieve/rank venues, and does not perform exact final-route verification. Live
provider validation, quota coordination, eligible-venue existence and comparisons
against network min-sum/min-max remain outstanding before research conclusions.
