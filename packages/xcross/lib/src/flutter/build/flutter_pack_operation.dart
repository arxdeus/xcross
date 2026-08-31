import 'dart:convert';
import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';
import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Groups the Flutter iOS `.app` packing entrypoint.
abstract final class FlutterPackOperation {
  /// Build the Flutter iOS `.app` for the project in the current directory.
  ///
  /// Bundle id comes from `ios/Runner/Info.plist` / `project.pbxproj` (same
  /// sources Flutter tooling uses). Deletes any prior bundle, then packs.
  static Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  artifactJunctionCapabilities({
    required String evidenceRoot,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
    Map<String, String> environment = const {},
    SwiftPmGateProbe probe = probeSwiftPmGate,
    SwiftPmGateRuntimeBinding? runtimeBinding,
  }) async {
    final evidence = SwiftPmGateEvidence(evidenceRoot);
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

  static Future<({String toolchain, String sdk})?> _cachedBuildIdentities(
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

  static Future<({bool swiftPmArtifact, bool packageLocalArtifact})?>
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

  static Future<void> _cacheCapabilities(
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

  static Future<void> _cacheBuildIdentities(
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

  static Future<({bool swiftPmArtifact, bool packageLocalArtifact})>
  resolveArtifactJunctionCapabilities({
    required SwiftPmWorkspace workspace,
    DarwinSdk? Function() currentDarwinSdk = DarwinSdk.current,
    bool? windows,
  }) async {
    final sdk = currentDarwinSdk();
    final isWindows = windows ?? Platform.isWindows;
    if (isWindows && sdk == null) {
      throw FlutterBuildError(
        'Darwin Swift SDK not found. Run '
        '`xcross sdk install <Xcode.xip>` first.',
      );
    }
    final cached = await _cachedBuildIdentities(workspace);
    final sdkIdentity =
        cached?.sdk ??
        jsonEncode(
          sdk == null
              ? const <String, Object>{}
              : await SdkInstall.sdkBuildIdentity(sdk.swiftSdkPath),
        );
    final toolchainIdentity =
        cached?.toolchain ??
        jsonEncode(
          isWindows
              ? await GeneratedPluginsPackage.resolveBuildToolchainIdentity(
                  sdk!,
                )
              : await SdkInstall.hostToolchainIdentity(),
        );
    if (cached == null) {
      await _cacheBuildIdentities(
        workspace,
        toolchain: toolchainIdentity,
        sdk: sdkIdentity,
      );
    }

    final platformIdentity =
        '${Platform.operatingSystem}-${Platform.operatingSystemVersion}';
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

  static Future<PackResult> pack({required FlutterBuildOptions options}) async {
    final projectRoot = Directory.current.path;
    final bundleId = IosBundleId.resolve(projectRoot);
    final workspace = SwiftPmWorkspace.forProject(projectRoot);

    final packer = FlutterPacker(
      projectRoot: projectRoot,
      bundleId: bundleId,
      options: options,
      artifactJunctionCapabilityResolver: () =>
          resolveArtifactJunctionCapabilities(workspace: workspace),
    );

    // Always delete any previous bundle BEFORE packing, otherwise stale
    // binaries from an earlier build get codesigned into the new one.
    final bundleDir = Directory(
      p.join(projectRoot, 'build', 'xcross-ios', '${packer.appName}.app'),
    );
    if (bundleDir.existsSync()) await bundleDir.delete(recursive: true);

    final appPath = await packer.pack();
    return PackResult(outputPath: appPath, bundleId: bundleId);
  }
}
