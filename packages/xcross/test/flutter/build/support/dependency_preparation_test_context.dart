import 'dart:io';

import 'package:cli_kit/host/macos/macos_host.dart';
import 'package:darwin_sdk_kit/host/macos/macos_darwin_toolchain_locations.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/iphone/iphone_target.dart';
import 'package:meta/meta.dart';
import 'package:open_apple_macros/host/shared/toolchain_plugin_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:xcross/src/host/macos/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/host/shared/flutter/native_host_tools.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/artifact_publication_lock.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_artifact_copy_policy.dart';
import 'package:xcross/src/host/shared/flutter/swiftpm/posix_checkout_attributes.dart';
import 'package:xcross/src/host/shared/sdk/inherited_swift_environment.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/dependency_preparation.dart';
import 'package:xcross/src/host/windows/flutter/swiftpm/swiftpm_host_policy.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_publication_coordinator.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_transport.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_layout.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_provenance.dart';
import 'package:xcross/src/shared/flutter/swiftpm/binary_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/extracted_artifact_recovery.dart';
import 'package:xcross/src/shared/flutter/swiftpm/network_retry.dart';
import 'package:xcross/src/shared/flutter/swiftpm/package_metadata.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';

import 'checkout_test_context.dart';

@internal
SwiftPmProcessPolicy<MacOSHost> dependencyTestProcessPolicy(
  CheckoutTestContext context,
  Directory root,
) => SwiftPmProcessPolicy(
  host: context.host,
  hostPolicy: const MacOSSwiftPmHostPolicy(),
  runner: context.runner,
  tools: AppleToolShimResolver(
    IPhoneTarget(context.host),
    context.runner,
    DarwinSdkRepository(
      context.host,
      log: context.runner.log,
      installBundle: p.join(root.path, 'unused-sdk'),
    ),
    DarwinToolchainResolver(
      context.runner,
      MacOSDarwinToolchainLocations(context.host),
    ),
    executable: p.join(root.path, 'unused-tool'),
    hostTools: RejectingDependencyNativeTools(context.host),
  ),
);

@internal
WindowsSwiftPmDependencyPreparation<MacOSHost> dependencyTestPreparation(
  CheckoutTestContext context,
  Directory root,
) {
  final host = context.host;
  final runner = context.runner;
  final fileSystem = context.fileSystem;
  final filesystem = context.filesystem;
  final targetPolicy = IPhoneFlutterTarget(IPhoneTarget(host));
  final hostPolicy = WindowsSwiftPmHostPolicy(
    runner,
    swiftEnvironment: const InheritedSwiftEnvironment(),
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
    metadata: SwiftPmPackageMetadata(fileSystem: fileSystem),
    processPolicy: processPolicy,
    networkRetry: SwiftPmNetworkRetry(runner: runner),
    binaryRecovery: recovery,
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
  );
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
  bool get flutterManagesIosEngineArtifacts =>
      throw StateError('Unexpected native tool query');
  @override
  ToolchainPluginLayoutInterface get toolchainPluginLayout =>
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
