/// Configure an ORS-compatible proxy with a public URL only. The proxy holds
/// the provider credential. An unauthenticated self-hosted ORS also works.
abstract final class OrsEndpoints {
  static const baseUrl = String.fromEnvironment(
    'ORS_BASE_URL',
    defaultValue: 'https://api.heigit.org/openrouteservice/v2',
  );
  static const matrix = '$baseUrl/matrix';
  static const isochrones = '$baseUrl/isochrones';
}
