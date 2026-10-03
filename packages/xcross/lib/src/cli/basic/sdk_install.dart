import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_extraction.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_links.dart';
import 'package:xcross/src/shared/sdk/sdk_archive_paths.dart';
import 'package:xcross/src/shared/sdk/sdk_build_identity.dart';
import 'package:xcross/src/shared/sdk/sdk_bundle_metadata_writer.dart';
import 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';
import 'package:xcross/src/shared/sdk/sdk_swift_toolchain.dart';

export 'package:xcross/src/shared/sdk/sdk_archive_links.dart';
export 'package:xcross/src/shared/sdk/sdk_install_constants.dart'
    show
        hostToolchainStampName,
        sdkIncludedFiles,
        sdkIncludedRoots,
        swiftSdkMismatchMarker;
export 'package:xcross/src/shared/sdk/sdk_metadata_platform.dart';

final class SdkInstall<T extends PlatformHostInterface> {
  SdkInstall(
    this.runner,
    this.repository, {
    required this.links,
    required this.swiftInstallGuidance,
    required List<String> swiftBuildTools,
    required List<SdkMetadataPlatformInterface<T>> metadataPlatforms,
  }) : swiftBuildTools = List.unmodifiable(swiftBuildTools),
       metadataPlatforms = List.unmodifiable(metadataPlatforms) {
    if (!identical(runner.host, repository.host)) {
      throw ArgumentError(
        'SDK repository and process runner must share a host',
      );
    }
    archive = SdkArchiveExtraction(runner, repository, links);
    metadata = SdkBundleMetadataWriter(repository, this.metadataPlatforms);
    toolchain = SdkSwiftToolchain(runner);
    fingerprints = SdkBuildIdentity(
      runner,
      repository,
      this.swiftBuildTools,
      this.metadataPlatforms,
    );
  }
  final ProcessRunner<T> runner;
  final DarwinSdkRepository<T> repository;
  final SdkArchiveLinksInterface links;
  final String swiftInstallGuidance;
  final List<String> swiftBuildTools;
  final List<SdkMetadataPlatformInterface<T>> metadataPlatforms;
  T get host => runner.host;
  Log get log => runner.log;

  late final SdkArchiveExtraction<T> archive;
  late final SdkBundleMetadataWriter<T> metadata;
  late final SdkSwiftToolchain<T> toolchain;
  late final SdkBuildIdentity<T> fingerprints;
  static String? sdkRelativePath(String name) =>
      SdkArchivePaths.sdkRelativePath(name);
  static String mismatchGuidance(String? detail) =>
      SdkSwiftToolchain.mismatchGuidance(detail);
  String ioPath(String path) => host.paths.ioPath(path);
  Stream<CpioEntry> xcodeAppEntries(String appPath) =>
      archive.xcodeAppEntries(appPath);
  Future<int> writeSdkEntries(
    Stream<CpioEntry> entries,
    String destDir, {
    void Function(int count)? onProgress,
    void Function(int done, int total)? onLinkProgress,
  }) => archive.writeSdkEntries(
    entries,
    destDir,
    onProgress: onProgress,
    onLinkProgress: onLinkProgress,
  );
  Set<String> materializedSdkAliases(String root, Map<String, String> links) =>
      archive.pathPolicy.materializedAliases(root, links);
  Future<void> materializeSwiftCompatibilityResources(String root) =>
      metadata.materializeSwiftCompatibilityResources(root);
  Future<void> writeSwiftSdkBundleMetadata(String root) =>
      metadata.writeSwiftSdkBundleMetadata(root);
  Future<void> replaceClangBuiltinHeaders(
    String root, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) => toolchain.replaceClangBuiltinHeaders(
    root,
    locateTool: locateTool,
    runProcess: runProcess,
  );
  Future<Map<String, Object>> swiftPmBuildToolchainIdentity({
    required String cCompilerPath,
    required String cxxCompilerPath,
    required String linkerPath,
    required String librarianPath,
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) => fingerprints.swiftPmBuildToolchainIdentity(
    cCompilerPath: cCompilerPath,
    cxxCompilerPath: cxxCompilerPath,
    linkerPath: linkerPath,
    librarianPath: librarianPath,
    locateTool: locateTool,
    runProcess: runProcess,
  );
  Future<Map<String, Object>> sdkBuildIdentity(String root) =>
      fingerprints.sdkBuildIdentity(root);
  Future<Map<String, String>> hostToolchainIdentity({
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) => toolchain.hostToolchainIdentity(
    locateTool: locateTool,
    runProcess: runProcess,
  );
  Map<String, String>? readHostToolchainStamp(String root) =>
      toolchain.readHostToolchainStamp(root);
  Future<String?> hostToolchainMismatch(
    String root, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) => toolchain.hostToolchainMismatch(
    root,
    locateTool: locateTool,
    runProcess: runProcess,
  );
}
