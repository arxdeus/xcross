import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:crypto/crypto.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_execution.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';

export 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';

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

const _gateImplementationVersion = 3;
const _extractorBuildVersion = 'xcross-1.3.1-swiftpm-gate-3';

final class SwiftPmGateEvidence<T extends PlatformHostInterface> {
  SwiftPmGateEvidence(this.root,{required this.execution,required this.platform,required this.platformIdentity,required this.fileSystem});
final SwiftPmGateExecution<T> execution;
final SwiftPmGatePlatform platform;
final String platformIdentity;
final SwiftPmArtifactFileSystem fileSystem;
  final _probeResults = <String, Future<bool>>{};

  final String root;

  Future<bool> verifies({
    required SwiftPmGateMode mode,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
    SwiftPmGateProbe? probe,
    SwiftPmGateRuntimeBinding? runtimeBinding,
  }) async {
    if (platformIdentity != this.platformIdentity) return false;
    try {
      final resolveRuntime = runtimeBinding ?? defaultRuntimeBinding;
      final runProbe =
          probe ??
          ({
            required mode,
            required root,
            required toolchainIdentity,
            required sdkIdentity,
          }) => platform.probe(
            execution,
            mode: mode,
            root: root,
            toolchainIdentity: toolchainIdentity,
            sdkIdentity: sdkIdentity,
          );
      final runtime = await resolveRuntime(
        mode: mode,
        root: root,
        platformIdentity: platformIdentity,
        toolchainIdentity: toolchainIdentity,
        sdkIdentity: sdkIdentity,
      );
      if (runtime == null) return false;
      if (await _validEvidence(mode, runtime)) return true;

      final cacheKey = sha256
          .convert(
            utf8.encode(
              jsonEncode(
                runtime,
              ),
            ),
          )
          .toString();
      final result = _probeResults.putIfAbsent(cacheKey, () async {
        try {
          final passed = await runProbe(
            mode: mode,
            root: root,
            toolchainIdentity: toolchainIdentity,
            sdkIdentity: sdkIdentity,
          ).timeout(const Duration(minutes: 10), onTimeout: () => false);
          if (!passed) return false;
          final binding = await resolveRuntime(
            mode: mode,
            root: root,
            platformIdentity: platformIdentity,
            toolchainIdentity: toolchainIdentity,
            sdkIdentity: sdkIdentity,
          );
          if (binding == null || jsonEncode(binding) != jsonEncode(runtime)) return false;
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
    final proofParent = fileSystem.directory(p.join(root, 'proofs'))
      ..createSync(recursive: true);
    final proof = await proofParent.createTemp('${mode.name}-');
    final nonce = List<int>.generate(32, (_) => _secureRandomByte());
    final target = fileSystem.directory(p.join(proof.path, 'target'))..createSync();
    final result = fileSystem.file(p.join(target.path, 'probe-result.bin'))
      ..writeAsBytesSync(nonce, flush: true);
    final alias = p.join(proof.path, 'junction');
    if (!await platform.createProofAlias(
      execution,
      alias,
      target.path,
    )) {
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
    final file = fileSystem.file(_path(mode));
    await file.parent.create(recursive: true);
    final temporary = fileSystem.file('${file.path}.tmp-$pid');
    await temporary.writeAsString(jsonEncode(payload), flush: true);
    await temporary.rename(file.path);
  }

  Future<bool> _validEvidence(
    SwiftPmGateMode mode,
    Map<String, Object?> binding,
  ) async {
    final file = fileSystem.file(_path(mode));
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
    final target = fileSystem.directory(p.join(proofRoot, 'target'));
    final alias = fileSystem.directory(p.join(proofRoot, 'junction'));
    final result = fileSystem.file(p.join(target.path, 'probe-result.bin'));
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
    return platform.verifyAlias(
      execution,
      alias.path,
      target.path,
    );
  }

  Future<Map<String, Object?>?> defaultRuntimeBinding({
    required SwiftPmGateMode mode,
    required String root,
    required String platformIdentity,
    required String toolchainIdentity,
    required String sdkIdentity,
  }) async {
    final toolchain = decodedSwiftPmGateMap(toolchainIdentity);
    final sdk = decodedSwiftPmGateMap(sdkIdentity);
    if (toolchain == null || sdk == null) return null;
    if (!await validSwiftPmGateToolchainIdentity(toolchain,fileSystem:fileSystem) ||
        !await validSwiftPmGateSdkIdentity(
          sdk,
          repository: execution.sdkRepository,fileSystem:fileSystem,
        )) {
      return null;
    }
    await fileSystem.directory(root).create(recursive: true);
    final volume = await platform.volumeIdentity(
      execution,
      root,
    );
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
}

Map<String, Object?>? decodedSwiftPmGateMap(String encoded) {
  try {
    final value = jsonDecode(encoded);
    return value is Map ? Map<String, Object?>.from(value) : null;
  } on FormatException {
    return null;
  }
}

Future<bool> validSwiftPmGateToolchainIdentity(
  Map<String, Object?> identity, {required SwiftPmArtifactFileSystem fileSystem}
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
    final file = fileSystem.file(executable['path'] as String);
    if (!file.existsSync()) return false;
    final resolved = file.resolveSymbolicLinksSync();
    final stat = fileSystem.file(resolved).statSync();
    if (p.normalize(resolved) != p.normalize(executable['path'] as String) ||
        stat.size != executable['size'] ||
        stat.modified.microsecondsSinceEpoch != executable['modified'] ||
        stat.changed.microsecondsSinceEpoch != executable['changed']) {
      return false;
    }
  }
  return true;
}

Future<bool> validSwiftPmGateSdkIdentity(
  Map<String, Object?> identity, {
  required DarwinSdkRepository repository,
  required SwiftPmArtifactFileSystem fileSystem,
}) async {
  if (identity['path'] is! String || identity['metadata'] is! Map) return false;
  final root = identity['path']! as String;
  if (!repository.isValidBundle(root)) return false;
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
    final file = fileSystem.file(p.join(root, entry.key as String));
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

int _secureRandomByte() => Random.secure().nextInt(256);
