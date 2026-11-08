# Offline isochrone area intersection

## API and interpretation

```dart
IsochroneIntersectionResult IsochroneIntersectionService.intersect(
  List<RoadNetworkIsochrone> isochrones,
);
```

Accepts 2–20 participants. Each participant is a nonempty GeoJSON
FeatureCollection of valid Polygon/MultiPolygon geometries. Features belonging
to one participant are **unioned**; the common area of all participant unions is
then intersected. This is an actual polygon Boolean operation, not an overlap
predicate or bounding-box/convex-hull/raster surrogate. A FeatureCollection must
represent the intended threshold, not a mixture of threshold contours; the
retrieval repository already checks range and group index. This geometry service
does not choose a threshold or enforce equal thresholds between participants.

The result exposes:

- `Map<String, dynamic>? geometry`: deeply immutable, GeoJSON-compatible Polygon
  or MultiPolygon, with closed rings and preserved holes/disconnected regions.
- `bool isEmpty`: true precisely when there is no polygonal area **at the
  documented numerical precision**; `geometry` is then null, never a fake point.
- `int participantCount` and `double gridSizeDegrees` (1e-7).

Lines or points from boundary-only contact are not venue regions and are omitted.
For mixed area-and-boundary intersections only the polygonal components survive.
All inputs are validated before an empty result is returned, including later
participants that would otherwise be skipped. No API request or optimization
algorithm is involved. Existing `IsochroneService` remains unchanged and still
performs its earlier candidate search, not genuine isochrone intersection.

## Library evaluation and licensing

Reviewed published package archives, source, licenses and test content. Versions
are pinned in pubspec.yaml and their archive hashes recorded by pubspec.lock.

| Candidate | Evaluation |
| --- | --- |
| **clipper2 0.0.3** | Selected for Boolean clipping and polygon-tree reconstruction. Pure Dart port of Angus Johnson's Clipper2 C# implementation; mobile, desktop and web support declared. Packaged polygon/line/hole-owner fixtures and expected-area/count tests. Boost Software License 1.0 is permissive. Last published release: April 2025; sparse Dart-port maintenance is a risk, distinct from the mature upstream algorithm. |
| **dart_jts 0.3.0+1** | Selected **only** for `IsValidOp` topology validation, including self-intersections, holes, and MultiPolygon validity. Pure Dart, mobile/web capable; Eclipse Distribution License 1.0, permissive BSD-style terms. Last published November 2023; maintenance is limited. Its public `Geometry.intersection` throws UnimplementedError, so it is explicitly not the clipping engine. Packaged geometry, validity and numerical tests exist, but the port is incomplete. |
| dts 0.2.1 / 0.1.4 | Newer JTS port, active releases through July 2026. Latest requires Dart >=3.11 and Flutter >=3.41, beyond this workspace. Compatible 0.1.4 has a BSD license with placeholder copyright and only a demonstration/export-generation file under test, insufficient clipping regression evidence for this choice. |
| turf 0.0.14 | Recent pure-Dart GeoJSON tooling, but no required polygon Boolean intersection operation; line-intersection/predicates do not suffice. |
| polybool / poly_bool_dart | Published versions require Dart <3; unsuitable for this SDK. |
| polygon_clipper | Flutter widget clipping, not a polygon-topology Boolean engine; also incompatible SDK constraints. |

Sources: [Clipper2 Dart](https://pub.dev/packages/clipper2),
[upstream Clipper2](https://github.com/AngusJohnson/Clipper2),
[dart_jts](https://github.com/moovida/dart_jts),
[dts](https://pub.dev/packages/dts), [turf](https://pub.dev/packages/turf).

Both selected licenses permit proprietary or open-source redistribution subject
to notice/attribution requirements and impose no reciprocal source-publication
obligation. The application has no explicit root license, so this is not a
statement about the application's eventual licensing. Full package license
notices are retained in `docs/licenses/`; preserve them when distributing sources
and include applicable third-party notices in app distributions. No dependency
source was copied into application code. No existing package versions were upgraded.

## Precision contract (mandatory)

This is finite-precision **planar GeoJSON** intersection, not exact-real or
spherical/geodesic geometry. Edges are straight in longitude/latitude, as specified
for GeoJSON coordinates. x is longitude, y is latitude. There is no reprojection:
affine translation/scaling preserves the defined planar segments and topology
apart from the explicitly described finite-precision clipping of new vertices.
No metric area or distance is computed; angular area is used only for winding
and zero-area validation. This does not introduce a distance-based projection
approximation to a venue-region calculation.

The service deliberately has a strict, visible domain:

1. Finite 2D WGS84 positions only. Higher-dimensional coordinates are rejected,
   not silently flattened. Poles and out-of-bounds coordinates are rejected.
2. Input vertices must lie on a **1e-7 degree grid** (allowance 1e-6 of a grid
   unit solely for binary floating representation). Off-grid inputs fail with
   `unsupportedPrecision`; they are never silently rounded onto a coarser grid.
3. The combined longitude and latitude spans must each be <=1 degree. This is a
   Bengaluru/local-region component, not an antimeridian or global engine.
4. Coordinates are translated around a common integer midpoint, then scaled by
   1e7. Local integer magnitudes are approximately <=5,000,001, keeping basic
   integer cross-products below JavaScript's 2^53 exact-integer bound. This limits
   risk from the Dart port's documented reduced integer precision on web; it is
   not a proof that all near-degenerate numerical cases are resolved identically.
5. Input rings must have at least two square grid units of area. Smaller valid
   rings fail explicitly: a probe confirmed Clipper2 discards one-cell triangles.
   A participant union unexpectedly losing all positive area also fails.
6. Clipper2 rounds newly created intersection vertices to the integer grid. A
   grid unit is about 1.1 cm north–south; east–west spacing depends on latitude.
   Rounding can change sub-grid slivers, merge tiny gaps, or erase extremely
   narrow intersections. Successive intersections can accumulate rounding and
   can depend on participant order near this resolution. **No exact-real or
   arbitrary-precision correctness claim is made.** A zero-area result means no
   retained polygon area at this resolution, not a physical impossibility proof.

Shell/hole winding is normalized for NonZero filling without changing point
locations. Polygon-tree hierarchy reconstructs each shell with its immediate
holes, while islands inside holes become separate polygon components. Original
feature topology and grid geometry are validated using JTS. Output is validated
before return; failure raises `computationFailed`. There is no buffer(0), topology
repair, simplify, snapping fallback, hull, inflation or retry at another scale.
Only redundant closure/winding representation is changed for the clipping API.
Clipper's normal removal of redundant collinear/duplicate vertices can change
vertex lists while preserving their area representation.

`IsochroneIntersectionException` distinguishes `invalidInput`,
`unsupportedPrecision` and `computationFailed`, with participant index where
applicable. Self-crossing rings, zero-area rings, open/short rings, holes outside
the shell, nested/overlapping holes and overlapping MultiPolygon interiors fail
explicitly. Multiple independent features of one participant may overlap and are
unioned as a set; this is not a repair of an invalid individual feature.

## Independent fixtures and verification

`tool/generate_intersection_fixtures.py` generates 20 analytic fixtures using
**Shapely 2.1.2 / GEOS 3.13.1**, independently of the Dart geometry libraries.
Input coordinates are synthetic test shapes, not observed Bengaluru road-network
results. Fixtures include expected full geometry and area. Simple expectations
are also hand-derived: the two-rectangle intersection is [2,1]–[4,3] (area 4);
the three-rectangle overlap is [2,3]–[5,5] (area 6); the clipped donut area is
64-16=48; a concave U clipped across its arms yields two disjoint rectangles.

Committed fixtures are embedded Dart JSON so tests run entirely offline on VM
and web. They are compared by full normalized geometry (not only area), allowing
only ring winding/start, redundant collinear vertices and component order to
vary. Every oracle case is tested in forward and reversed participant order.
The selected Clipper2 archive's 214 packaged regression cases also passed in a
separate scratch Dart package; these are supplementary upstream tests, not
independent real-world validation.
Additional tests cover malformed geometry, topology, precision rejections,
immutability, coordinate ordering, per-participant feature union, and validation
of later participants even after an earlier disjoint pair.

To regenerate, use a separate Python environment with `shapely==2.1.2` (the
recorded run used NumPy 2.5.4); the script records the GEOS version in its output.
Run from repository root, then `dart format test/fixtures/intersection_fixtures.dart`.
Regeneration is not required to run Dart tests and makes no network/API calls.

```sh
source /workspace/.toolchains/flutter-env.sh
flutter test --no-pub test/isochrone_intersection_service_test.dart \
  test/isochrone_repository_test.dart test/routing_repository_test.dart
flutter test --no-pub --platform chrome test/isochrone_intersection_service_test.dart
flutter analyze --no-pub
git diff --check
```

Recorded verification: 126 relevant VM tests passed (69 geometry plus 57 existing
retrieval/routing/state/optimization tests); the same 69 geometry tests passed in
Chromium. No tests failed. Analysis reports no new findings: the existing 3
warnings and 9 informational findings remain (nonzero analyzer exit status).
Whitespace checks passed, including the new untracked files.

This component is ready for a subsequent integration step **within its precision
and extent contract**, not an end-to-end research method. Threshold search,
provider quotas, group orchestration, venue filtering, real ORS validation and
exact final-route evaluation remain separate work. Real-world near-degenerate
polygons and grid sensitivity need study before scientific conclusions or wider
deployment; no performance measurements or experimental claims are made here.
