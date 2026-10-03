import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_mode.dart';
import 'package:xcross/src/shared/flutter/swiftpm/gate_platform.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class PosixSwiftPmGatePlatform implements SwiftPmGatePlatform {
  const PosixSwiftPmGatePlatform({required this.fileSystem});
  @override
  final SwiftPmArtifactFileSystem fileSystem;
  @override
  bool matchesTarget<P extends PlatformHostInterface>(
    FlutterTargetBuildPolicy<P> policy,
  ) => true;
  @override
  Future<String?> volumeIdentity(String path) async {
    final stat = fileSystem.directory(path).statSync();
    return '${stat.mode}:${stat.changed.microsecondsSinceEpoch}';
  }

  @override
  Future<bool> createProofAlias(String alias, String target) async {
    await fileSystem.link(alias).create(target);
    return fileSystem.directory(alias).existsSync();
  }

  @override
  Future<bool> verifyAlias(String alias, String target) =>
      fileSystem.isAliasTo(alias, target);
  @override
  Future<bool> probe({
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
  }) async => false;
}
