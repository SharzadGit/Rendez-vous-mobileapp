# Candidate venue matrix evaluation

```dart
VenueRoutingService({http.Client? client});
Future<VenueRoutingResult> evaluate({
  required List<UserLocation> participants,
  required List<ResearchVenue> venues,
  VenueRoutingConfig config = const VenueRoutingConfig(),
  double? thresholdSeconds,
});
```

Supply the same fixed eligible venue collection for comparative experiments.
This service does not apply eligibility policy, rank venues, or choose an optimum.
Input participant order and venue order (including stable venue IDs) are retained.
Duplicate venue IDs are invalid. Duplicate coordinates are allowed and remain
separate rows/columns; there is no caching or deduplication. Inputs are snapshotted
before asynchronous work. The legacy RoutingRepository is unchanged.

## Requests and budgets

POST `https://api.heigit.org/openrouteservice/v2/matrix/{profile}` using the
central OrsEndpoints configuration and existing Authorization header. Participants
are grouped by the existing walking/cycling/driving mapping. Each request lists
source coordinates first and venue coordinates second, all [longitude, latitude].
Explicit `sources` and `destinations` contain string location indices;
`metrics: ["duration"]` requests seconds. Response rows correspond to the requested
participant sources; columns correspond to the requested venue destinations.
Reverse venue-to-participant durations are never used.

VenueRoutingConfig defaults: maxLocations=50, maxPairs=400, maxRequests=100,
timeout=30 seconds, thresholdToleranceSeconds=0.000001. These are configurable
local limits, NOT verified hosted plan limits. Set them to the provider's actual
limits before live use. Each profile's participants are chunked to at most
min(maxLocations-1,maxPairs); destination chunks then fit both the remaining
location count and floor(maxPairs/sourceCount). Requests are sequential and
counted when started, including failures. There are no retries. Budgets may
stop partway through a venue: all unrequested pairs retain budgetExceeded.
Invalid origins/modes and invalid venue coordinates do not consume requests.
Invalid configuration or duplicate IDs return inputError without requests.

A failed batch marks all its pairs with the typed failure and processing continues
within budget. This is not global rate limiting; even sequential calls can exceed
quotas. HTTP status and Retry-After are retained in each request record for caller
orchestration. Request timeout bounds awaiting the response but does not cancel
the underlying HTTP operation; timed-out transport may still consume quota.
Injected clients are caller-owned. No live API calls were used in validation.

## Results and numerical conventions

PairTravelTime distinguishes success, unreachable, invalidCoordinates,
unsupportedMode, malformedResponse, providerFailure, timeout, budgetExceeded,
and invalidInput. Only success contains seconds. Null matrix cells are explicitly
unreachable. Wrong dimensions, invalid JSON, negative/nonfinite values, and the
legacy numeric sentinel 999999 invalidate the entire batch before any result is
accepted. This conservatively rejects even a provider-supplied literal 999999
rather than risking sentinel contamination. No arbitrary unreachable penalty
enters research statistics. Provider body text is not copied into diagnostics.

Every venue remains present. Aggregates are populated only when every participant
pair succeeds: total seconds, arithmetic mean, maximum, population standard
deviation (divisor N), and individual pair durations in participant order.
Variance is calculated with scaling by the maximum to avoid raw square overflow;
nonfinite aggregates invalidate that venue's pairs explicitly. This is ordinary
double-precision arithmetic, not arbitrary-precision summation. Zero durations
are valid. No rounding to minutes is performed.

matrixThresholdVerified is null without a supplied threshold or with incomplete/
unreachable results. Otherwise it is true iff every duration is <= threshold
plus the configured absolute tolerance in seconds (implemented by subtraction to
avoid overflow); false preserves a threshold-violating venue and its durations.
A nonnegative finite threshold/tolerance is mandatory when supplied. Pair statuses,
threshold flag, and inputError distinguish failure reasons without filtering cases.

Telemetry includes request records with profile, original participant/venue
indices, elapsed request wall time, response HTTP status, Retry-After and typed
request outcome. actualMatrixRequests, candidateVenuesEvaluated (all supplied
venue rows, including unsuccessful ones), reachablePairs, unreachablePairs,
apiFailures (failed request batches, including malformed responses and timeouts),
requestDuration (sum of request elapsed times), and cacheHits (always zero) are
available. Local validation/budget failures are not API failures. These are runtime
telemetry, not experimental performance claims.

## Scientific limits

Matrix feasibility is NOT final directions-route verification. It does not prove
physical entrance access, venue opening, pedestrian legality, capacity, or stable
road-network data. ORS may snap coordinates; snapping metadata and provider data
versions are not yet archived by this layer. A reproducible live experiment must
archive its input dataset, policy/configuration, provider metadata and raw responses
through separate orchestration. No actual Bengaluru venue dataset or live ORS
experiment has been validated. There is no UI integration, route geometry
verification, venue ranking, or min-sum/min-max optimizer here.
