import 'package:apple_developer_kit/src/grandslam/anisette/grandslam_endpoints.dart';

/// Common consumer-facing Anisette source. GrandSlam and Developer Services
/// only need fresh headers plus the endpoint URL bag; the native mechanism
/// producing OTP values is platform-specific.
abstract interface class AnisetteProvider {
  Future<Map<String, String>> fetchAnisetteHeaders();

  Future<GrandSlamEndpoints> resolveGrandSlamEndpoints();

  void close();
}
