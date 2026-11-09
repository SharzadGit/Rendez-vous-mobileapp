import 'dart:convert';

/// Immutable point venue. Missing provenance remains absent.
class ResearchVenue {
  final String id, name, category;
  final double longitude, latitude;
  final String? osmId;
  final Map<String, dynamic> metadata;
  ResearchVenue({
    required this.id,
    required this.name,
    required this.category,
    required this.longitude,
    required this.latitude,
    this.osmId,
    Map<String, dynamic> metadata = const {},
  }) : metadata = freezeJson(metadata) as Map<String, dynamic>;
}

dynamic freezeJson(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
      value.map((k, v) => MapEntry(k, freezeJson(v))),
    );
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(freezeJson));
  if (value == null ||
      value is String ||
      value is bool ||
      (value is num && value.isFinite)) {
    return value;
  }
  throw const FormatException('Metadata must be finite JSON data.');
}

class VenueDataset {
  final String version;
  final Map<String, dynamic> metadata;
  final List<ResearchVenue> venues;
  VenueDataset._(this.version, this.metadata, this.venues);

  /// FeatureCollection with nonempty dataset_version and Point features.
  /// Throws FormatException for invalid data; never invents provenance.
  factory VenueDataset.fromGeoJson(String text) {
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final version = data['dataset_version'] as String;
      if (data['type'] != 'FeatureCollection' || version.trim().isEmpty) {
        throw const FormatException('Invalid dataset header');
      }
      final venues = <ResearchVenue>[];
      for (final raw in data['features'] as List) {
        final f = raw as Map<String, dynamic>;
        final g = f['geometry'] as Map<String, dynamic>;
        final p = f['properties'] as Map<String, dynamic>;
        final c = g['coordinates'] as List;
        if (f['type'] != 'Feature' || g['type'] != 'Point' || c.length != 2) {
          throw const FormatException('Expected 2D Point feature');
        }
        venues.add(
          ResearchVenue(
            id: f['id'] as String,
            name: p['name'] as String,
            category: p['category'] as String,
            longitude: (c[0] as num).toDouble(),
            latitude: (c[1] as num).toDouble(),
            osmId: p['osm_id'] as String?,
            metadata: p,
          ),
        );
      }
      validateVenues(venues);
      return VenueDataset._(
        version,
        freezeJson(data['metadata'] ?? <String, dynamic>{})
            as Map<String, dynamic>,
        List.unmodifiable(venues),
      );
    } catch (e) {
      throw FormatException('Invalid venue dataset: $e');
    }
  }
}

void validateVenues(List<ResearchVenue> venues) {
  final ids = <String>{};
  for (final v in venues) {
    if (v.id.trim().isEmpty ||
        v.name.trim().isEmpty ||
        v.category.trim().isEmpty ||
        !ids.add(v.id) ||
        !v.longitude.isFinite ||
        !v.latitude.isFinite ||
        v.longitude.abs() > 180 ||
        v.latitude.abs() > 90 ||
        (v.osmId != null &&
            !RegExp(r'^(node|way|relation)/[1-9][0-9]*$').hasMatch(v.osmId!))) {
      throw const FormatException('Invalid venue or duplicate stable ID');
    }
  }
}
