# Road-network isochrone retrieval

`IsochroneRepository({http.Client? client, Duration timeout = const Duration(seconds: 30)})`
provides:

```dart
Future<RoadNetworkIsochrone> getIsochrone({
  required LatLng origin,
  required TravelMode travelMode,
  required Duration travelTime,
});
```

This retrieval layer is not yet connected to either optimization method and does
not implement intersection. The existing `IsochroneService` still uses its previous
candidate-search algorithm; its name must not be taken as evidence of actual
isochrone intersection. No experimental or performance claims follow from these
mocked tests.

## Contract and provenance

POST `https://api.heigit.org/openrouteservice/v2/isochrones/{profile}`, with JSON body:

```json
{
  "locations": [[77.5946, 12.9716]],
  "range_type": "time",
  "location_type": "start",
  "range": [600.0]
}
```

Headers: `Authorization` uses the existing `ApiKeys.ors` binding;
`Content-Type: application/json`; `Accept: application/geo+json`.
`Duration` converts microseconds to seconds (fractional seconds are retained).
Coordinates are WGS84 `[longitude, latitude]`, not `[latitude, longitude]`.
`start` means reachability outward from the participant's origin, consistent with
participant-to-meeting routing. Modes reuse `TravelMode.orsProfile`:
`driving-car`, `cycling-regular` (bicycle), and `foot-walking`.
Legacy two-wheeler/motorcycle mode fails explicitly before any network call.

`RoadNetworkIsochrone` retains the origin, mode, threshold, and deeply immutable
GeoJSON FeatureCollection, including all returned features, Polygon rings and
holes, MultiPolygon components, additional coordinate ordinates, properties,
bounding boxes and metadata. No client-side approximation, simplification,
repair, reprojection, or union occurs. Structural validation checks closed rings,
finite coordinates and ranges, feature types, group index 0 and the requested
threshold. It does not establish polygon topology (self-intersections, hole
containment, etc.). Provider polygons themselves approximate network reachability;
the client preserves them and makes no claim of exact boundaries.

Sources verified from the official ORS repository:

- [Isochrone endpoint documentation](https://github.com/GIScience/openrouteservice/blob/main/docs/api-reference/endpoints/isochrones/index.md)
- [Request schema](https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/requests/isochrones/IsochronesRequest.java)
- [Endpoint controller](https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/controllers/IsochronesAPI.java)
- [Profile enumeration](https://github.com/GIScience/openrouteservice/blob/main/ors-api/src/main/java/org/heigit/ors/api/APIEnums.java)
- [Isochrone error codes](https://github.com/GIScience/openrouteservice/blob/main/ors-engine/src/main/java/org/heigit/ors/isochrones/IsochronesErrorCodes.java)

## Errors and unreachable origins

`IsochroneException.kind` distinguishes invalid inputs, unsupported modes,
transport/provider failures, timeouts, empty results, and malformed responses.
Provider failures retain HTTP status, ORS code/message when present, and
`Retry-After`. Empty features raise an explicit no-reachable-area error; absent or
invalid geometries fail rather than yielding synthetic geometry. Unsnappable or
unreachable origins can produce provider failures or empty results. A generic
provider error or empty response is not proof of a particular physical cause;
retain and inspect provider diagnostics rather than reclassifying every error as
an unreachable origin. Authentication, quota and server failures never fall back
to another profile or a geometric circle.

The configurable timeout bounds how long the caller waits; `Future.timeout` does
not cancel an in-flight request. An injected client remains caller-owned. There
are no automatic retries. Tests use `MockClient` and require no valid API key.

## Provider limits and future groups of 20

A call always sends **one origin, one profile, one threshold**. A later group
orchestrator can use this API for up to 20 participants with different modes,
without depending on a 20-origin batch being accepted. No group orchestrator,
concurrency scheduler, or intersection is implemented here.

Hosted ORS imposes limits on locations per request, range values/intervals,
maximum range (depending on profile), per-minute throughput and daily quotas.
Limits may differ by deployment and account. The authoritative hosted
[restrictions page](https://openrouteservice.org/restrictions/) returned HTTP 403
from this workspace during implementation, so current numeric caps and the
account's entitlements could not be verified. Do not infer hosted limits from
self-hosted defaults. Before live experiments, record the applicable plan,
profile-specific maximum time range, origin and interval caps, and request quotas.
The repository does not guess a cap or silently clamp the requested range;
provider rejections are explicit errors (e.g. ORS 3004 for exceeding a maximum).

Twenty origins at one threshold require 20 HTTP requests; T tested thresholds
require up to 20*T calls without caching. Each retry adds calls and potentially
quota consumption. Future orchestration must budget this separately from matrix
evaluation, throttle across all profile groups, honor `Retry-After`, and handle
partial failures explicitly. Sequential calls alone do not guarantee compliance
with a provider's per-minute limit. For reproducibility, archive exact requests,
raw responses/metadata, profile, threshold and the documented provider limits;
returned metadata is preserved but cannot guarantee a reproducible hosted road
network across future provider updates. No live isochrone requests were made.

The HeiGIT host migration uses the centralized `OrsEndpoints` configuration for
matrix, isochrone retrieval, and the optimizer cache endpoint identity. Existing
API keys and request semantics are unchanged. Endpoint regression tests are
mocked; live behavior on the migrated host has not been validated.
