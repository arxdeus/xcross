import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/swiftpm_binary_fixture.dart';
import 'package:xcross/src/flutter/build/ios_plugin_package.dart';

enum SwiftPmGateMode { swiftPmArtifact, packageLocalArtifact }

typedef SwiftPmGateProbe =
    Future<bool> Function({
      required SwiftPmGateMode mode,
      required String root,
      required String toolchainIdentity,
      required String sdkIdentity,
    });

typedef SwiftPmGateRuntimeBinding =
    Future<Map<String, Object?>?> Function({
      required SwiftPmGateMode mode,
      required String root,
      required String platformIdentity,
      required String toolchainIdentity,
      required String sdkIdentity,
    });

typedef SwiftPmGateRun =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      required Duration timeout,
      Map<String, String>? environment,
    });

final _probeResults = <String, Future<bool>>{};
const _gateImplementationVersion = 3;
const _extractorBuildVersion = 'xcross-1.3.1-swiftpm-gate-3';

final class SwiftPmGateEvidence {
  const SwiftPmGateEvidence(this.root);

  final String root;

  Future<bool> verifies({
    required SwiftPmGateMode mode,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
    SwiftPmGateProbe probe = probeSwiftPmGate,
    SwiftPmGateRuntimeBinding? runtimeBinding,
  }) async {
    if (!Platform.isWindows && platformIdentity.startsWith('windows-')) {
      return false;
    }
    try {
      final resolveRuntime = runtimeBinding ?? _defaultRuntimeBinding;
      final runtime = await resolveRuntime(
        mode: mode,
        root: root,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
      );
      if (runtime != null && await _validEvidence(mode, runtime)) return true;

      final cacheKey = sha256
          .convert(
            utf8.encode(
              jsonEncode(
                runtime ??
                    {
                      'mode': mode.name,
                      'platform': platformIdentity,
                      'toolchain': toolchainIdentity,
                      'sdk': sdkIdentity,
                    },
              ),
            ),
          )
          .toString();
      final result = _probeResults.putIfAbsent(cacheKey, () async {
        try {
          final passed = await probe(
            mode: mode,
            root: root,
            toolchainIdentity: toolchainIdentity,
            sdkIdentity: sdkIdentity,
          ).timeout(const Duration(minutes: 10), onTimeout: () => false);
          if (!passed) return false;
          final binding =
              runtime ??
              await resolveRuntime(
                mode: mode,
                root: root,
                platformIdentity: platformIdentity,
                toolchainIdentity: toolchainIdentity,
                sdkIdentity: sdkIdentity,
              );
          if (binding == null) return false;
          await _record(mode, binding);
          return await _validEvidence(mode, binding);
        } on Object {
          return false;
        }
      });
      final passed = await result;
      if (passed && identical(_probeResults[cacheKey], result)) {
        unawaited(_probeResults.remove(cacheKey));
      }
      return passed;
    } on Object {
      return false;
    }
  }

  String _path(SwiftPmGateMode mode) =>
      p.join(root, '${mode.name}.evidence.json');

  Future<void> _record(
    SwiftPmGateMode mode,
    Map<String, Object?> binding,
  ) async {
    final proofParent = Directory(p.join(root, 'proofs'))
      ..createSync(recursive: true);
    final proof = await proofParent.createTemp('${mode.name}-');
    final nonce = List<int>.generate(32, (_) => _secureRandomByte());
    final target = Directory(p.join(proof.path, 'target'))..createSync();
    final result = File(p.join(target.path, 'probe-result.bin'))
      ..writeAsBytesSync(nonce, flush: true);
    final alias = p.join(proof.path, 'junction');
    if (!await _createProofAlias(alias, target.path)) {
      await proof.delete(recursive: true);
      throw StateError('Could not create proof junction');
    }
    final payload = {
      ...binding,
      'proof': {
        'directory': p.relative(proof.path, from: root),
        'resultDigest': sha256.convert(result.readAsBytesSync()).toString(),
      },
    };
    final file = File(_path(mode));
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp-$pid');
    await temporary.writeAsString(jsonEncode(payload), flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> _validEvidence(
    SwiftPmGateMode mode,
    Map<String, Object?> binding,
  ) async {
    final file = File(_path(mode));
    if (!file.existsSync()) return false;
    final encoded = jsonDecode(await file.readAsString());
    if (encoded is! Map) return false;
    final proof = encoded['proof'];
    if (proof is! Map || proof['directory'] is! String) return false;
    final persistedBinding = Map<String, Object?>.from(encoded)
      ..remove('proof');
    if (!const DeepCollectionEquality().equals(persistedBinding, binding)) {
      return false;
    }
    final proofRoot = p.normalize(p.join(root, proof['directory'] as String));
    if (!p.isWithin(p.normalize(root), proofRoot)) return false;
    final target = Directory(p.join(proofRoot, 'target'));
    final alias = Directory(p.join(proofRoot, 'junction'));
    final result = File(p.join(target.path, 'probe-result.bin'));
    if (!target.existsSync() || !alias.existsSync() || !result.existsSync()) {
      return false;
    }
    if (sha256.convert(result.readAsBytesSync()).toString() !=
        proof['resultDigest']) {
      return false;
    }
    if (p.normalize(await alias.resolveSymbolicLinks()) !=
        p.normalize(await target.resolveSymbolicLinks())) {
      return false;
    }
    return !Platform.isWindows || await _isJunction(alias.path);
  }
}

Future<Map<String, Object?>?> _defaultRuntimeBinding({
  required SwiftPmGateMode mode,
  required String root,
  required String platformIdentity,
  required String toolchainIdentity,
  required String sdkIdentity,
}) async {
  final toolchain = _decodedMap(toolchainIdentity);
  final sdk = _decodedMap(sdkIdentity);
  if (toolchain == null || sdk == null) return null;
  if (!await validSwiftPmGateToolchainIdentity(toolchain) ||
      !await validSwiftPmGateSdkIdentity(sdk)) {
    return null;
  }
  await Directory(root).create(recursive: true);
  final volume = await _volumeIdentity(root);
  if (volume == null) return null;
  return {
    'formatVersion': 3,
    'gateImplementationVersion': _gateImplementationVersion,
    'extractorBuildVersion': _extractorBuildVersion,
    'mode': mode.name,
    'platform': platformIdentity,
    'toolchain': toolchain,
    'sdk': sdk,
    'volume': volume,
  };
}

Map<String, Object?>? _decodedMap(String encoded) {
  try {
    final value = jsonDecode(encoded);
    return value is Map ? Map<String, Object?>.from(value) : null;
  } on FormatException {
    return null;
  }
}

Future<bool> validSwiftPmGateToolchainIdentity(
  Map<String, Object?> identity,
) async {
  const versionedTools = {'swift-package', 'swift-build', 'swiftc'};
  const tools = {
    ...versionedTools,
    'clang',
    'clang++',
    'ld64.lld',
    'librarian',
  };
  if (identity.keys.toSet().difference(tools).isNotEmpty ||
      tools.difference(identity.keys.toSet()).isNotEmpty) {
    return false;
  }
  for (final name in tools) {
    final executable = identity[name];
    if (executable is! Map ||
        executable['path'] is! String ||
        executable['size'] is! int ||
        executable['modified'] is! int ||
        executable['changed'] is! int ||
        executable['digest'] is! String ||
        (versionedTools.contains(name) && executable['version'] is! String)) {
      return false;
    }
    final file = File(executable['path'] as String);
    if (!file.existsSync()) return false;
    final resolved = file.resolveSymbolicLinksSync();
    final stat = File(resolved).statSync();
    if (p.normalize(resolved) != p.normalize(executable['path'] as String) ||
        stat.size != executable['size'] ||
        stat.modified.microsecondsSinceEpoch != executable['modified'] ||
        stat.changed.microsecondsSinceEpoch != executable['changed']) {
      return false;
    }
  }
  return true;
}

Future<bool> validSwiftPmGateSdkIdentity(Map<String, Object?> identity) async {
  if (identity['path'] is! String || identity['metadata'] is! Map) return false;
  final root = identity['path']! as String;
  if (!DarwinSdk.isValidBundle(root)) return false;
  final metadata = identity['metadata']! as Map;
  if (metadata.isEmpty) return false;
  for (final entry in metadata.entries) {
    if (entry.key is! String || entry.value is! Map) return false;
    final expected = entry.value as Map;
    if (expected['size'] is! int ||
        expected['modified'] is! int ||
        expected['changed'] is! int ||
        expected['digest'] is! String) {
      return false;
    }
    final file = File(p.join(root, entry.key as String));
    if (!file.existsSync()) return false;
    final stat = file.statSync();
    if (stat.size != expected['size'] ||
        stat.modified.microsecondsSinceEpoch != expected['modified'] ||
        stat.changed.microsecondsSinceEpoch != expected['changed']) {
      return false;
    }
  }
  return true;
}

Future<String?> _volumeIdentity(String path) async {
  if (!Platform.isWindows) {
    final stat = await FileStat.stat(path);
    return '${stat.mode}:${stat.changed.microsecondsSinceEpoch}';
  }
  final result = await _runBounded('fsutil.exe', [
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

int _secureRandomByte() => Random.secure().nextInt(256);

Future<bool> _createProofAlias(String alias, String target) async {
  if (Platform.isWindows) return _createJunction(alias, target, _runBounded);
  await Link(alias).create(target);
  return Directory(alias).existsSync();
}

Future<bool> _isJunction(String path) async {
  final result = await _runBounded('fsutil.exe', [
    'reparsepoint',
    'query',
    path,
  ], timeout: const Duration(seconds: 5));
  return result.exitCode == 0 &&
      RegExp('0xa0000003', caseSensitive: false).hasMatch('${result.stdout}');
}

Future<bool> probeSwiftPmGate({
  required SwiftPmGateMode mode,
  required String root,
  required String toolchainIdentity,
  required String sdkIdentity,
  SwiftPmGateRun run = _runBounded,
  bool? windows,
}) async {
  if (!(windows ?? Platform.isWindows)) return false;
  Directory? probeRoot;
  var stage = 'validating toolchain';
  try {
    final identity = jsonDecode(toolchainIdentity);
    if (identity is! Map) return false;
    final swiftPackage = await _boundExecutable(identity['swift-package'], run);
    final swiftBuild = await _boundExecutable(identity['swift-build'], run);
    if (swiftPackage == null ||
        swiftBuild == null ||
        !await validSwiftPmGateToolchainIdentity(
          Map<String, Object?>.from(identity),
        )) {
      return false;
    }
    String toolPath(String name) => (identity[name] as Map)['path']! as String;
    final encodedSdk = _decodedMap(sdkIdentity);
    final sdkPath = encodedSdk?['path'];
    if (sdkPath is! String) return false;
    final sdk = DarwinSdk(sdkPath);
    if (!DarwinSdk.isValidBundle(sdkPath) ||
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
    final package = Directory(p.join(probeRoot.path, 'package'))..createSync();
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
      if (!await _createJunction(junction, fixture.path, run)) return false;
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
    final toolset = await GeneratedPluginsPackage.writeToolset(
      outputDir: package.path,
      linkerPath: toolPath('ld64.lld'),
      cCompilerPath: toolPath('clang'),
      cxxCompilerPath: toolPath('clang++'),
      librarianPath: toolPath('librarian'),
      windows: true,
    );
    final swiftSdksPath = p.dirname(sdkPath);
    final resolve = GeneratedPluginsPackage.swiftResolveArguments(
      pluginsDir: package.path,
      scratchPath: scratch,
      swiftSdksPath: swiftSdksPath,
      toolsetPath: toolset,
    );
    final build = GeneratedPluginsPackage.swiftBuildArguments(
      pluginsDir: package.path,
      scratchPath: scratch,
      swiftSdksPath: swiftSdksPath,
      iosSdk: sdk.iPhoneOSSdk(),
      flutterFrameworkSlice: package.path,
      toolsetPath: toolset,
      windows: true,
    );
    final environment = GeneratedPluginsPackage.swiftProcessEnvironment(
      windows: true,
    );

    if (mode == SwiftPmGateMode.swiftPmArtifact) {
      if (!await _runSwift(
        swiftPackage,
        resolve.skip(1).toList(),
        environment,
        run,
      )) {
        return false;
      }
      final artifacts = Directory(scratch)
          .listSync(recursive: true, followLinks: false)
          .whereType<Directory>()
          .where((entry) => p.basename(entry.path) == 'GateFixture.xcframework')
          .toList();
      if (artifacts.length != 1) return false;
      junction = artifacts.single.path;
      await artifacts.single.delete(recursive: true);
      if (!await _createJunction(junction, fixture.path, run)) return false;
    }

    for (var repetition = 0; repetition < 2; repetition++) {
      stage = 'resolve ${repetition + 1}';
      if (!await _runSwift(
        swiftPackage,
        resolve.skip(1).toList(),
        environment,
        run,
      )) {
        return false;
      }
      stage = 'build ${repetition + 1}';
      if (!await _runSwift(
        swiftBuild,
        build.skip(1).toList(),
        environment,
        run,
      )) {
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

Future<ProcessResult> _runBounded(
  String executable,
  List<String> arguments, {
  required Duration timeout,
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    executable,
    arguments,
    environment: environment,
  );
  try {
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final error = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final exitCode = await process.exitCode.timeout(timeout);
    return ProcessResult(process.pid, exitCode, await output, await error);
  } on TimeoutException {
    process.kill();
    await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1,
    );
    rethrow;
  }
}

final class DeepCollectionEquality {
  const DeepCollectionEquality();

  bool equals(Object? left, Object? right) {
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      return left.entries.every(
        (entry) =>
            right.containsKey(entry.key) &&
            equals(entry.value, right[entry.key]),
      );
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (var index = 0; index < left.length; index++) {
        if (!equals(left[index], right[index])) return false;
      }
      return true;
    }
    return left == right;
  }
}
