import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_identity.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';

final class SwiftPmArtifactCapabilities<T extends PlatformHostInterface> {
  SwiftPmArtifactCapabilities({required this.paths,required this.fileSystem,required this.execution,required this.platform,required this.identities,this.probe,this.runtimeBinding});
final HostPathsInterface paths;
final SwiftPmArtifactFileSystem fileSystem;
final SwiftPmGateExecution<T> execution;
final SwiftPmGatePlatform platform;
final SwiftPmArtifactIdentities identities;
final SwiftPmGateProbe? probe;
final SwiftPmGateRuntimeBinding? runtimeBinding;
  final _evidence = <String, SwiftPmGateEvidence<T>>{};
  Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  artifactJunctionCapabilities({
    required String evidenceRoot,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
    Map<String, String> environment = const {},
    SwiftPmGateProbe? probe,
    SwiftPmGateRuntimeBinding? runtimeBinding,
  }) async {
    final evidence = _evidence.putIfAbsent(
      paths.pathKey(evidenceRoot),
      () => SwiftPmGateEvidence(evidenceRoot,execution:execution,platform:platform,platformIdentity:platformIdentity,fileSystem:fileSystem),
    );
    return (
      swiftPmArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.swiftPmArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe ?? this.probe,
        runtimeBinding: runtimeBinding ?? this.runtimeBinding,
      ),
      packageLocalArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.packageLocalArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe ?? this.probe,
        runtimeBinding: runtimeBinding ?? this.runtimeBinding,
      ),
    );
  }

  Future<void> _cacheCapabilities(
    SwiftPmWorkspace workspace, {
    required String platform,
    required String toolchain,
    required String sdk,
    required ({bool swiftPmArtifact, bool packageLocalArtifact}) capabilities,
  }) async {
    final file = fileSystem.file(workspace.gateCapabilityCache);
    await file.parent.create(recursive: true);
    final temporary = fileSystem.file('${file.path}.tmp-$pid');
    await temporary.writeAsString(
      jsonEncode({
        'platform': platform,
        'toolchain': toolchain,
        'sdk': sdk,
        'swiftPmArtifact': capabilities.swiftPmArtifact,
        'packageLocalArtifact': capabilities.packageLocalArtifact,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<void> _cacheBuildIdentities(
    SwiftPmWorkspace workspace, {
    required String toolchain,
    required String sdk,
  }) async {
    final file = fileSystem.file(workspace.gateIdentityCache);
    await file.parent.create(recursive: true);
    final temporary = fileSystem.file('${file.path}.tmp-$pid');
    await temporary.writeAsString(
      jsonEncode({'toolchain': jsonDecode(toolchain), 'sdk': jsonDecode(sdk)}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  resolveArtifactJunctionCapabilities({
    required SwiftPmWorkspace workspace,
  }) async {
    final identity=await identities.resolve();
    final sdkIdentity=identity.sdk;
    final toolchainIdentity=identity.toolchain;
    final platformIdentity=identity.platform;
    await _cacheBuildIdentities(workspace,toolchain:toolchainIdentity,sdk:sdkIdentity);
    final capabilities = await artifactJunctionCapabilities(
      evidenceRoot: workspace.gateEvidence,
      platformIdentity: platformIdentity,
      toolchainIdentity: toolchainIdentity,
      sdkIdentity: sdkIdentity,
    );
    await _cacheCapabilities(
      workspace,
      platform: platformIdentity,
      toolchain: toolchainIdentity,
      sdk: sdkIdentity,
      capabilities: capabilities,
    );
    return capabilities;
  }
}
