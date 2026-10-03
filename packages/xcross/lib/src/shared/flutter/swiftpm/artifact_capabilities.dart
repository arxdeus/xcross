import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

final class SwiftPmArtifactCapabilities<T extends PlatformHostInterface> {
  SwiftPmArtifactCapabilities(this.runtime);
  final SwiftPmRuntime<T> runtime;
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
      runtime.host.paths.pathKey(evidenceRoot),
      () => SwiftPmGateEvidence(evidenceRoot, runtime),
    );
    return (
      swiftPmArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.swiftPmArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe,
        runtimeBinding: runtimeBinding,
      ),
      packageLocalArtifact: await evidence.verifies(
        mode: SwiftPmGateMode.packageLocalArtifact,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
        probe: probe,
        runtimeBinding: runtimeBinding,
      ),
    );
  }

  Future<({String toolchain, String sdk})?> _cachedBuildIdentities(
    SwiftPmWorkspace workspace,
  ) async {
    final file = File(workspace.gateIdentityCache);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['toolchain'] is! Map<String, Object?> ||
          decoded['sdk'] is! Map<String, Object?>) {
        return null;
      }
      final toolchain = decoded['toolchain']! as Map<String, Object?>;
      final sdk = decoded['sdk']! as Map<String, Object?>;
      return (toolchain: jsonEncode(toolchain), sdk: jsonEncode(sdk));
    } on Object {
      return null;
    }
  }

  Future<({bool swiftPmArtifact, bool packageLocalArtifact})?>
  _cachedCapabilities(
    SwiftPmWorkspace workspace, {
    required String platform,
    required String toolchain,
    required String sdk,
  }) async {
    final file = File(workspace.gateCapabilityCache);
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['platform'] != platform ||
          decoded['toolchain'] != toolchain ||
          decoded['sdk'] != sdk ||
          decoded['swiftPmArtifact'] is! bool ||
          decoded['packageLocalArtifact'] is! bool) {
        return null;
      }
      return (
        swiftPmArtifact: decoded['swiftPmArtifact']! as bool,
        packageLocalArtifact: decoded['packageLocalArtifact']! as bool,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _cacheCapabilities(
    SwiftPmWorkspace workspace, {
    required String platform,
    required String toolchain,
    required String sdk,
    required ({bool swiftPmArtifact, bool packageLocalArtifact}) capabilities,
  }) async {
    final file = File(workspace.gateCapabilityCache);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
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
    final file = File(workspace.gateIdentityCache);
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
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
    final sdk = runtime.sdkRepository.current();
    final cached = await _cachedBuildIdentities(workspace);
    final sdkIdentity =
        cached?.sdk ??
        jsonEncode(
          sdk == null
              ? const <String, Object>{}
              : await runtime.sdkIdentity.sdkBuildIdentity(sdk.swiftSdkPath),
        );
    final toolchainIdentity =
        cached?.toolchain ??
        jsonEncode(
          await runtime.hostPolicy.buildToolchainIdentity(runtime, sdk),
        );
    if (cached == null) {
      await _cacheBuildIdentities(
        workspace,
        toolchain: toolchainIdentity,
        sdk: sdkIdentity,
      );
    }

    final platformIdentity = runtime.sdkIdentity.platformIdentity;
    final cachedCapabilities = await _cachedCapabilities(
      workspace,
      platform: platformIdentity,
      toolchain: toolchainIdentity,
      sdk: sdkIdentity,
    );
    if (cachedCapabilities != null) return cachedCapabilities;

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
