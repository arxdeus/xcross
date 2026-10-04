import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/swiftpm_binary_fixture.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/build_plan.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/process_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/toolchain.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class WindowsSwiftPmGatePlatform<T extends PlatformHostInterface>
    implements SwiftPmGatePlatform {
  WindowsSwiftPmGatePlatform({
    required this.execution,
    required this.fixtureGenerator,
    required this.fileSystem,
    required this.sdkRepository,
    required this.toolchain,
    required this.processPolicy,
    required this.buildPlan,
    required this.targetPolicy,
    required this.log,
  }) {
    final target = targetPolicy.target;
    if (!identical(execution.host, target.host) ||
        !identical(sdkRepository.host, target.host) ||
        !identical(processPolicy.host, target.host) ||
        !identical(processPolicy.runner.host, target.host) ||
        !identical(buildPlan.runner, processPolicy.runner) ||
        !identical(toolchain.hostBuildServices.target, target) ||
        !identical(toolchain.filesystem.host, target.host) ||
        !identical(toolchain.filesystem.artifactFileSystem, fileSystem) ||
        !identical(fixtureGenerator.fileSystem, target.host.fileSystem) ||
        !identical(fixtureGenerator.paths, target.host.paths.context) ||
        !identical(buildPlan.filesystem, toolchain.filesystem) ||
        !identical(log, processPolicy.runner.log)) {
      throw ArgumentError(
        'SwiftPM gate requires coherent configured target, host, filesystem and runner ports',
      );
    }
    const candidates = [
      SwiftPmBinaryFixtureLibrary(identifier: 'ios-arm64'),
      SwiftPmBinaryFixtureLibrary(
        identifier: 'ios-arm64-simulator',
        variant: 'simulator',
      ),
    ];
    final matching = candidates
        .where(
          (candidate) => targetPolicy.matchesLibraryVariant(candidate.variant),
        )
        .toList();
    if (matching.length != 1) {
      throw ArgumentError('Gate requires one matching fixture library');
    }
    fixtureLibrary = matching.single;
  }
  final SwiftPmBinaryFixtureGenerator fixtureGenerator;
  late final SwiftPmBinaryFixtureLibrary fixtureLibrary;
  final SwiftPmGateProcess execution;
  @override
  final SwiftPmArtifactFileSystem fileSystem;
  final DarwinSdkRepository<T> sdkRepository;
  final SwiftPmToolchain<T> toolchain;
  final SwiftPmProcessPolicy<T> processPolicy;
  final SwiftPmBuildPlan<T> buildPlan;
  final FlutterTargetBuildPolicy<T> targetPolicy;
  final Log log;
  @override
  bool matchesTarget<P extends PlatformHostInterface>(
    FlutterTargetBuildPolicy<P> policy,
  ) => identical(policy, targetPolicy);
  @override
  Future<String?> volumeIdentity(String path) async {
    final result = await execution.runGateProcess('fsutil.exe', [
      'fsinfo',
      'volumeinfo',
      p.windows.rootPrefix(p.windows.absolute(path)),
    ], timeout: const Duration(seconds: 5));
    if (result.exitCode != 0) return null;
    final match = RegExp(
      r'Volume Serial Number\s*:\s*(\S+)',
      caseSensitive: false,
    ).firstMatch('${result.stdout}');
    return match?.group(1)?.toLowerCase();
  }

  @override
  Future<bool> createProofAlias(String alias, String target) =>
      _createJunction(alias, target);
  @override
  Future<bool> verifyAlias(String alias, String target) =>
      fileSystem.isAliasTo(alias, target);
  @override
  Future<bool> probe({
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
  }) async {
    Directory? probeRoot;
    var retainProbeRoot = false;
    var stage = 'validating toolchain';
    try {
      final identity = jsonDecode(toolchainIdentity);
      if (identity is! Map) return false;
      final swiftPackage = await _boundExecutable(identity['swift-package']);
      final swiftBuild = await _boundExecutable(identity['swift-build']);
      if (swiftPackage == null ||
          swiftBuild == null ||
          !await validSwiftPmGateToolchainIdentity(
            Map<String, Object?>.from(identity),
            fileSystem: fileSystem,
          )) {
        return false;
      }
      String toolPath(String name) =>
          (identity[name] as Map)['path']! as String;
      final encodedSdk = decodedSwiftPmGateMap(sdkIdentity);
      final sdkPath = encodedSdk?['path'];
      if (sdkPath is! String) return false;
      final sdk = DarwinSdk(sdkPath);
      if (!sdkRepository.isValidBundle(sdkPath) ||
          p.normalize(sdk.swiftSdkPath) != p.normalize(sdkPath)) {
        return false;
      }

      stage = 'creating fixture';
      final probeParent = fileSystem.directory(
        p.join(root, '.probe-${mode.name}'),
      );
      await probeParent.create(recursive: true);
      probeRoot = await probeParent.createTemp('run-');
      final fixture = fixtureGenerator.generateXcframework(
        root: probeRoot.path,
        name: 'GateFixture',
        library: fixtureLibrary,
      );
      final package = fileSystem.directory(p.join(probeRoot.path, 'package'))
        ..createSync();
      final scratch = p.join(probeRoot.path, 'scratch');
      String? junction;

      if (mode == SwiftPmGateMode.packageLocalArtifact) {
        junction = p.join(package.path, 'artifacts', 'GateFixture.xcframework');
        fileSystem.directory(p.dirname(junction)).createSync();
        fixtureGenerator.writeGatePackage(
          root: package.path,
          targetName: 'GateFixture',
          path: 'artifacts/GateFixture.xcframework',
        );
        stage = 'creating package-local junction';
        if (!await _createJunction(junction, fixture.path)) {
          return false;
        }
      } else {
        fixtureGenerator.archiveXcframework(
          framework: fixture,
          output: p.join(package.path, 'GateFixture.zip'),
        );
        fixtureGenerator.writeGatePackage(
          root: package.path,
          targetName: 'GateFixture',
          path: 'GateFixture.zip',
        );
      }

      stage = 'writing toolset';
      final toolset = await toolchain.writeToolset(
        outputDir: package.path,
        linkerPath: toolPath('ld64.lld'),
        cCompilerPath: toolPath('clang'),
        cxxCompilerPath: toolPath('clang++'),
        librarianPath: toolPath('librarian'),
      );
      final swiftSdksPath = p.dirname(sdkPath);
      final resolve = processPolicy.swiftResolveArguments(
        pluginsDir: package.path,
        scratchPath: scratch,
        swiftSdksPath: swiftSdksPath,
        toolsetPath: toolset,
        swiftSdkTriple: targetPolicy.target.buildPlatform.swiftSdkTriple,
      );
      final build = buildPlan.swiftBuildArguments(
        pluginsDir: package.path,
        scratchPath: scratch,
        swiftSdksPath: swiftSdksPath,
        iosSdk: sdkRepository.iosSdk(
          sdk,
          target: targetPolicy.target.buildPlatform,
        ),
        flutterFrameworkSlice: package.path,
        toolsetPath: toolset,
        swiftSdkTriple: targetPolicy.target.buildPlatform.swiftSdkTriple,
      );
      final environment = processPolicy.swiftProcessEnvironment();

      if (mode == SwiftPmGateMode.swiftPmArtifact) {
        if (!await _runSwift(swiftPackage, resolve, environment)) {
          return false;
        }
        final artifacts = fileSystem
            .directory(scratch)
            .listSync(recursive: true, followLinks: false)
            .whereType<Directory>()
            .where(
              (entry) => p.basename(entry.path) == 'GateFixture.xcframework',
            )
            .toList();
        if (artifacts.length != 1) return false;
        junction = artifacts.single.path;
        await artifacts.single.delete(recursive: true);
        if (!await _createJunction(junction, fixture.path)) {
          return false;
        }
      }

      for (var repetition = 0; repetition < 2; repetition++) {
        stage = 'resolve ${repetition + 1}';
        if (!await _runSwift(swiftPackage, resolve, environment)) {
          return false;
        }
        stage = 'build ${repetition + 1}';
        if (!await _runSwift(swiftBuild, build, environment)) {
          return false;
        }
        stage = 'verifying junction ${repetition + 1}';
        final actual = p.normalize(
          await fileSystem.directory(junction!).resolveSymbolicLinks(),
        );
        final expected = p.normalize(await fixture.resolveSymbolicLinks());
        if (!p.equals(actual, expected)) {
          log.output.stderr(
            'SwiftPM junction gate target mismatch at $stage: '
            'expected $expected, got $actual',
          );
          return false;
        }
      }
      return true;
    } on SwiftPmGateLiveProcessException catch (error, stackTrace) {
      retainProbeRoot = true;
      log.output.stderr(
        'SwiftPM junction gate retained ${probeRoot?.path} at $stage: $error',
      );
      log.output.stderr(stackTrace.toString());
      return false;
    } on Object catch (error, stackTrace) {
      log.output.stderr('SwiftPM junction gate failed at $stage: $error');
      log.output.stderr(stackTrace.toString());
      return false;
    } finally {
      if (!retainProbeRoot && probeRoot != null && probeRoot.existsSync()) {
        await probeRoot.delete(recursive: true);
        final parent = probeRoot.parent;
        if (parent.existsSync() && parent.listSync().isEmpty) {
          await parent.delete();
        }
      }
    }
  }

  Future<String?> _boundExecutable(Object? encoded) async {
    if (encoded is! Map ||
        encoded['path'] is! String ||
        encoded['version'] is! String) {
      return null;
    }
    final recordedPath = encoded['path'] as String;
    if (recordedPath.isEmpty || !fileSystem.file(recordedPath).existsSync()) {
      return null;
    }
    final resolvedPath = await fileSystem
        .file(recordedPath)
        .resolveSymbolicLinks();
    if (p.normalize(resolvedPath) != p.normalize(recordedPath)) return null;
    final result = await execution.runGateProcess(resolvedPath, const [
      '--version',
    ], timeout: const Duration(seconds: 5));
    final output = '${result.stdout}'.trim().isEmpty
        ? '${result.stderr}'.trim()
        : '${result.stdout}'.trim();
    if (result.exitCode != 0 ||
        output.split(RegExp(r'\r?\n')).first != encoded['version']) {
      return null;
    }
    return resolvedPath;
  }

  Future<bool> _createJunction(String alias, String target) async {
    final result = await execution.runGateProcess('cmd.exe', [
      '/c',
      'mklink',
      '/J',
      p.windows.normalize(alias),
      p.windows.normalize(target),
    ], timeout: const Duration(seconds: 5));
    return result.exitCode == 0 && fileSystem.directory(alias).existsSync();
  }

  Future<bool> _runSwift(
    String swift,
    List<String> arguments,
    Map<String, String>? environment,
  ) async {
    final result = await execution.runGateProcess(
      swift,
      arguments,
      environment: environment,
      timeout: const Duration(minutes: 5),
    );
    if (result.exitCode != 0) {
      log.output.stderr(
        'SwiftPM junction gate command failed (${result.exitCode}): '
        '${result.stderr}\n${result.stdout}',
      );
      return false;
    }
    return true;
  }
}
