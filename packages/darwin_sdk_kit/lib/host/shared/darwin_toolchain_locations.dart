abstract interface class DarwinToolchainLocationsInterface {
  List<String> llvmToolDirectories();
  String get linkerInstallationHint;
  String get clangInstallationHint;
}
