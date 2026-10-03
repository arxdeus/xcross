import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/swiftpm_binary_fixture.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';

final class WindowsSwiftPmGatePlatform implements SwiftPmGatePlatform {
  const WindowsSwiftPmGatePlatform();
  @override
  Future<String?> volumeIdentity<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String path,
  ) async {
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
  Future<bool> createProofAlias<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String alias,
    String target,
  ) => _createJunction(alias, target, execution.runGateProcess);
  @override
  Future<bool> verifyAlias<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution,
    String alias,
    String target,
  ) => execution.artifactFileSystem.isAliasTo(alias, target);
  @override
  Future<bool> probe<T extends PlatformHostInterface>(
    SwiftPmGateExecution<T> execution, {
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
    SwiftPmGateRun? run,
  }) async {
    final execute = run ?? execution.runGateProcess;
    Directory? probeRoot;
    var stage = 'validating toolchain';
    try {
      final identity = jsonDecode(toolchainIdentity);
      if (identity is! Map) return false;
      final swiftPackage = await _boundExecutable(
        identity['swift-package'],
        execute,
      );
      final swiftBuild = await _boundExecutable(
        identity['swift-build'],
        execute,
      );
      if (swiftPackage == null ||
          swiftBuild == null ||
          !await validSwiftPmGateToolchainIdentity(
            Map<String, Object?>.from(identity),
          )) {
        return false;
      }
      String toolPath(String name) =>
          (identity[name] as Map)['path']! as String;
      final encodedSdk = decodedSwiftPmGateMap(sdkIdentity);
      final sdkPath = encodedSdk?['path'];
      if (sdkPath is! String) return false;
      final sdk = DarwinSdk(sdkPath);
      if (!execution.sdkRepository.isValidBundle(sdkPath) ||
          p.normalize(sdk.swiftSdkPath) != p.normalize(sdkPath)) {
        return false;
      }

      stage = 'creating fixture';
      final probeParent = Directory(p.join(root, '.probe-${mode.name}'));
      await probeParent.create(recursive: true);
      probeRoot = await probeParent.createTemp('run-');
      final fixture = SwiftPmBinaryFixture.generateXcframework(
        root: probeRoot.path,
        name: 'GateFixture',
      );
      final package = Directory(p.join(probeRoot.path, 'package'))
        ..createSync();
      final scratch = p.join(probeRoot.path, 'scratch');
      String? junction;

      if (mode == SwiftPmGateMode.packageLocalArtifact) {
        junction = p.join(package.path, 'artifacts', 'GateFixture.xcframework');
        Directory(p.dirname(junction)).createSync();
        SwiftPmBinaryFixture.writeGatePackage(
          root: package.path,
          targetName: 'GateFixture',
          path: 'artifacts/GateFixture.xcframework',
        );
        stage = 'creating package-local junction';
        if (!await _createJunction(junction, fixture.path, execute)) {
          return false;
        }
      } else {
        SwiftPmBinaryFixture.archiveXcframework(
          framework: fixture,
          output: p.join(package.path, 'GateFixture.zip'),
        );
        SwiftPmBinaryFixture.writeGatePackage(
          root: package.path,
          targetName: 'GateFixture',
          path: 'GateFixture.zip',
        );
      }

      stage = 'writing toolset';
      final toolset = await execution.toolchain.writeToolset(
        outputDir: package.path,
        linkerPath: toolPath('ld64.lld'),
        cCompilerPath: toolPath('clang'),
        cxxCompilerPath: toolPath('clang++'),
        librarianPath: toolPath('librarian'),
      );
      final swiftSdksPath = p.dirname(sdkPath);
      final resolve = execution.processPolicy.swiftResolveArguments(
        pluginsDir: package.path,
        scratchPath: scratch,
        swiftSdksPath: swiftSdksPath,
        toolsetPath: toolset,
      );
      final build = execution.buildPlan.swiftBuildArguments(
        pluginsDir: package.path,
        scratchPath: scratch,
        swiftSdksPath: swiftSdksPath,
        iosSdk: execution.sdkRepository.iosSdk(
          sdk,
          target: execution.target.buildPlatform,
        ),
        flutterFrameworkSlice: package.path,
        toolsetPath: toolset,
      );
      final environment = execution.processPolicy.swiftProcessEnvironment();

      if (mode == SwiftPmGateMode.swiftPmArtifact) {
        if (!await _runSwift(swiftPackage, resolve, environment, execute)) {
          return false;
        }
        final artifacts = Directory(scratch)
            .listSync(recursive: true, followLinks: false)
            .whereType<Directory>()
            .where(
              (entry) => p.basename(entry.path) == 'GateFixture.xcframework',
            )
            .toList();
        if (artifacts.length != 1) return false;
        junction = artifacts.single.path;
        await artifacts.single.delete(recursive: true);
        if (!await _createJunction(junction, fixture.path, execute)) {
          return false;
        }
      }

      for (var repetition = 0; repetition < 2; repetition++) {
        stage = 'resolve ${repetition + 1}';
        if (!await _runSwift(swiftPackage, resolve, environment, execute)) {
          return false;
        }
        stage = 'build ${repetition + 1}';
        if (!await _runSwift(swiftBuild, build, environment, execute)) {
          return false;
        }
        stage = 'verifying junction ${repetition + 1}';
        final actual = p.normalize(
          await Directory(junction!).resolveSymbolicLinks(),
        );
        final expected = p.normalize(await fixture.resolveSymbolicLinks());
        if (!p.equals(actual, expected)) {
          stderr.writeln(
            'SwiftPM junction gate target mismatch at $stage: '
            'expected $expected, got $actual',
          );
          return false;
        }
      }
      return true;
    } on Object catch (error, stackTrace) {
      stderr.writeln('SwiftPM junction gate failed at $stage: $error');
      stderr.writeln(stackTrace);
      return false;
    } finally {
      if (probeRoot != null && probeRoot.existsSync()) {
        await probeRoot.delete(recursive: true);
        final parent = probeRoot.parent;
        if (parent.existsSync() && parent.listSync().isEmpty) {
          await parent.delete();
        }
      }
    }
  }

  Future<String?> _boundExecutable(Object? encoded, SwiftPmGateRun run) async {
    if (encoded is! Map ||
        encoded['path'] is! String ||
        encoded['version'] is! String) {
      return null;
    }
    final recordedPath = encoded['path'] as String;
    if (recordedPath.isEmpty || !File(recordedPath).existsSync()) return null;
    final resolvedPath = await File(recordedPath).resolveSymbolicLinks();
    if (p.normalize(resolvedPath) != p.normalize(recordedPath)) return null;
    final result = await run(resolvedPath, const [
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

  Future<bool> _createJunction(
    String alias,
    String target,
    SwiftPmGateRun run,
  ) async {
    final result = await run('cmd.exe', [
      '/c',
      'mklink',
      '/J',
      p.windows.normalize(alias),
      p.windows.normalize(target),
    ], timeout: const Duration(seconds: 5));
    return result.exitCode == 0 && Directory(alias).existsSync();
  }

  Future<bool> _runSwift(
    String swift,
    List<String> arguments,
    Map<String, String>? environment,
    SwiftPmGateRun run,
  ) async {
    final result = await run(
      swift,
      arguments,
      environment: environment,
      timeout: const Duration(minutes: 5),
    );
    if (result.exitCode != 0) {
      stderr.writeln(
        'SwiftPM junction gate command failed (${result.exitCode}): '
        '${result.stderr}\n${result.stdout}',
      );
      return false;
    }
    return true;
  }
}
