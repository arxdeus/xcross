abstract interface class IosBuildPlatformInterface {
  String get sdkName;
  String get platformName;
  String get swiftSdkTriple;
  String get linkerPlatform;
  String buildTriple(String minimumVersion);
  String minimumVersionFlag(String minimumVersion);
}
