import 'dart:async';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/flutter/build/internal/swiftpm_gate_evidence.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/shared/flutter/swiftpm/runtime.dart';

final class PosixSwiftPmGatePlatform implements SwiftPmGatePlatform {
  const PosixSwiftPmGatePlatform();
  @override
  Future<String?> volumeIdentity<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String path,
  ) async {
    final stat = await FileStat.stat(path);
    return '${stat.mode}:${stat.changed.microsecondsSinceEpoch}';
  }

  @override
  Future<bool> createProofAlias<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String alias,
    String target,
  ) async {
    await Link(alias).create(target);
    return Directory(alias).existsSync();
  }

  @override
  Future<bool> verifyAlias<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime,
    String alias,
    String target,
  ) => runtime.artifactFileSystem.isAliasTo(alias, target);
  @override
  Future<bool> probe<T extends PlatformHostInterface>(
    SwiftPmRuntime<T> runtime, {
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
    SwiftPmGateRun? run,
  }) async => false;
}
