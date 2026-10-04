import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:darwin_sdk_kit/host/macos/macos_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/pinned_dependency_resolver.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_preparation.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_git_repository.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_manifest_normalizer.dart';
import 'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import 'checkout_test_context.dart';

@internal
WindowsSwiftPmDependencyPreparation<MacOSHost> dependencyTestPreparation(
  CheckoutTestContext context,
  Directory root, {
  required RecordingDependencyManifestPolicy manifestPolicy,
  required SwiftPmGitPackageCloner cloner,
}) {
  final host = context.host;
  final runner = context.runner;
  final fileSystem = context.fileSystem;
  final filesystem = context.filesystem;
  final targetPolicy = IPhoneFlutterTarget(IPhoneTarget(host));
  final hostPolicy = WindowsSwiftPmHostPolicy(runner);
  final normalizer = SwiftPmCheckoutManifestNormalizer(
    fileSystem: fileSystem,
    filesystem: filesystem,
    attributes: const PosixSwiftPmCheckoutAttributes(),
    policy: manifestPolicy,
  );
  final sdk = DarwinSdkRepository(
    host,
    log: runner.log,
    installBundle: p.join(root.path, 'unused-sdk'),
  );
  final tools = AppleToolShimResolver(
    targetPolicy.target,
    runner,
    sdk,
    DarwinToolchainResolver(runner, MacOSDarwinToolchainLocations(host)),
    executable: p.join(root.path, 'unused-tool'),
    hostTools: RejectingDependencyNativeTools(host),
  );
  final processPolicy = SwiftPmProcessPolicy(
    host: host,
    hostPolicy: hostPolicy,
    runner: runner,
    tools: tools,
  );
  final coordinator = SwiftPmPublicationCoordinator(
    locks: FileSwiftPmPublicationLockProvider(fileSystem),
    pathKey: host.paths.pathKey,
  );
  final copyPolicy = PosixSwiftPmArtifactCopyPolicy(fileSystem);
  const transport = RejectingDependencyArchiveTransport();
  final layout = SwiftPmBinaryLayout(
    artifactFileSystem: fileSystem,
    targetPolicy: targetPolicy,
  );
  final provenance = SwiftPmBinaryProvenance(
    artifactFileSystem: fileSystem,
    host: host,
    hostPolicy: hostPolicy,
    runner: runner,
  );
  final recovery = SwiftPmBinaryRecovery(
    artifactFileSystem: fileSystem,
    binaryLayout: layout,
    binaryProvenance: provenance,
    copyPolicy: copyPolicy,
    filesystem: filesystem,
    host: host,
    publicationCoordinator: coordinator,
    targetPolicy: targetPolicy,
    transport: transport,
  );
  return WindowsSwiftPmDependencyPreparation(
    runner: runner,
    checkout: context.checkout,
    fileSystem: fileSystem,
    manifestNormalizer: normalizer,
    metadata: SwiftPmPackageMetadata(fileSystem: fileSystem),
    processPolicy: processPolicy,
    networkRetry: SwiftPmNetworkRetry(runner: runner),
    binaryPreparation: SwiftPmBinaryPreparation(
      artifactFileSystem: fileSystem,
      copyPolicy: copyPolicy,
      filesystem: filesystem,
      host: host,
      publicationCoordinator: coordinator,
      targetPolicy: targetPolicy,
      transport: transport,
    ),
    binaryRecovery: recovery,
    binaryProvenance: provenance,
    extractedArtifacts: SwiftPmExtractedArtifactRecovery(
      artifactFileSystem: fileSystem,
      binaryLayout: layout,
      binaryRecovery: recovery,
      checkoutAttributes: const PosixSwiftPmCheckoutAttributes(),
      copyPolicy: copyPolicy,
      filesystem: filesystem,
      host: host,
      publicationCoordinator: coordinator,
      targetPolicy: targetPolicy,
      transport: transport,
    ),
    pinnedResolver: WindowsSwiftPmPinnedDependencyResolver(
      runner: runner,
      fileSystem: fileSystem,
      filesystem: filesystem,
      repository: cloner,
      manifestNormalizer: normalizer,
    ),
  );
}

@internal
final class RecordingDependencyManifestPolicy
    implements SwiftPmVendoredManifestPolicy {
  RecordingDependencyManifestPolicy({this.failNormalization = false});
  final bool failNormalization;
  final List<({String directory, Set<String> products})> calls = [];
  @override
  String normalizeHostManifest(String manifest) =>
      throw StateError('Unexpected host manifest normalization');
  @override
  Future<String> normalize(
    String manifest, {
    required String packageDir,
    required Set<String> consumedProducts,
    Map<String, List<String>>? fallbackSwiftModules,
  }) async {
    calls.add((directory: packageDir, products: Set.of(consumedProducts)));
    if (failNormalization) throw StateError('fixture normalization failed');
    return manifest.replaceAll('fixtureOld', 'fixtureNew');
  }
}

@internal
final class RecordingDependencyCloner implements SwiftPmGitPackageCloner {
  final List<({String git, String url, String ref, String destination})> calls =
      [];
  @override
  Future<void> cloneGitPackage(
    String git,
    String url,
    String ref,
    String destination,
  ) async {
    calls.add((git: git, url: url, ref: ref, destination: destination));
    Directory(destination).createSync(recursive: true);
    File(p.join(destination, 'Package.swift')).writeAsStringSync('fixtureOld');
  }
}

@internal
final class RejectingDependencyArchiveTransport
    implements SwiftPmArchiveTransport {
  const RejectingDependencyArchiveTransport();
  @override
  Future<void> download(Uri url, File destination, int maximumBytes) {
    fail('No real archive/network operation is permitted in dependency tests');
  }
}

@internal
final class RejectingDependencyNativeTools
    implements NativeHostTools<MacOSHost> {
  const RejectingDependencyNativeTools(this.host);
  @override
  final MacOSHost host;
  @override
  String get artifactPlatform =>
      throw StateError('Unexpected native tool query');
  @override
  String get engineCacheDirectory =>
      throw StateError('Unexpected native tool query');
  @override
  String get previewMacroPrologue =>
      throw StateError('Unexpected native tool query');
  @override
  Future<HostCompiler> compiler(String clang) async =>
      throw StateError('Unexpected native compilation');
  @override
  Future<String> forwarder(String executable, String? launcher) async =>
      throw StateError('Unexpected native tool operation');
  @override
  Future<void> link(String path, String target) async =>
      throw StateError('Unexpected native tool operation');
}
