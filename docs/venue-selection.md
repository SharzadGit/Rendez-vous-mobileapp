# Offline research venue selection

`VenueSelectionService.select({required Map<String,dynamic>? region,
required List<ResearchVenue> candidates, required VenueEligibilityPolicy policy})`
returns `VenueSelectionResult`: selected, noEligibleVenues, invalidData, or
geometryFailure, with immutable venues and an optional diagnostic. Null region
means an explicitly empty intersection; an empty/malformed Polygon is an error.
All candidates are validated even when the region is empty. Geometry is validated
even when candidates are empty. Failures never return partial selections.

`ResearchVenue` holds a stable nonempty string ID, name, category, longitude,
latitude, optional typed OSM ID (`node/123`, `way/123`, `relation/123`), and deeply
immutable JSON metadata. Coordinates must be finite WGS84 values. Duplicate
stable IDs are rejected, including identical rows; no silent deduplication or
merging occurs. Different IDs at the same location remain separate candidates.
OSM aliases across distinct IDs are not automatically conflated: dataset curation
must establish the canonical stable identity before comparing methods.

`VenueEligibilityPolicy(id:, categories:, includeBoundary:)` is immutable and
explicit. Categories match exactly and case-sensitively; an empty set permits
nothing. Policy ID must be nonempty. The boolean boundary rule is mandatory:
false excludes both shell and hole boundaries; true includes both. Hole interiors
are always excluded. This is a category policy, not a claim of opening hours,
accessibility, capacity, safety, or permission to meet. Results sort by Dart string
ID comparison, independent of input order, without distance ranking or a winner.

Geometry uses the already pinned dart_jts implementation: IsValidOp validates the
whole MultiPolygon and PointLocator performs robust ray-crossing containment.
Concavities, interior rings, and disconnected components retain their actual
geometry. Invalid rings, overlapping MultiPolygon components, self-intersections,
non-2D coordinates and unsupported types are rejected, not repaired. Geometry
coordinates follow [longitude, latitude], on the existing 10^-7-degree grid
(binary tolerance 10^-6 grid units), with combined extent at most one degree per
axis. Poles and antimeridian endpoints are excluded. No clipping or quantization
is performed here; unlike the intersection operation, containment introduces no
new vertices or minimum-area clipping threshold. Venue points need not be on the
grid and are never snapped. Calculations use planar double-precision coordinates,
not geodesic edges. Boundary classification is numerical, not a guarantee of
physical road accessibility. Existing intersection rounding limitations carry
through in the supplied region. JTS is an existing older port; offline regression
coverage does not establish robustness for every possible degeneracy.

## Fixed dataset

`VenueDataset.fromGeoJson(String text)` parses a versioned FeatureCollection and
throws FormatException on invalid data. Load file bytes outside this service;
there are no network requests or filesystem dependencies here. Example schema
(the empty collection intentionally asserts no real venues):

```json
{
  "type": "FeatureCollection",
  "dataset_version": "your-immutable-version",
  "metadata": {},
  "features": []
}
```

Each feature must have type Feature, a nonempty string `id`, a 2D Point geometry,
and properties with nonempty `name` and `category`; optional `osm_id` follows the
typed format above. All properties are retained as immutable venue metadata.
Collection metadata may record `source`, `extraction_date`, `filtering_policy`,
license, extraction query, and checksum when actually known. These fields are
preserved as supplied JSON, not independently verified or fabricated; missing
provenance remains absent. A version label is required but is not a content hash.
Archive the exact dataset bytes/checksum and complete eligibility policy with
experiment outputs. Tests contain only synthetic fixtures, not Bengaluru records.

Share the identical frozen dataset and policy across Weiszfeld, isochrone,
network min-sum, and network min-max evaluation. This module imposes no provider
query or method-specific sampling and does not modify any optimization algorithm.
An area venue must supply an independently justified point such as a verified
entrance; this loader will not substitute a centroid for a venue footprint.

No UI integration, live provider validation, venue ranking, or final participant-
to-venue road-route verification is included. A geometrically eligible candidate
is not a verified reachable venue or network min-max optimum. Empty selections
refer only to this fixed dataset, region and policy, not global venue absence.
