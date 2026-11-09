import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/swiftpm/gate_mode.dart';
import 'package:xcross/src/target/shared/swiftpm/swiftpm_target_policy.dart';

@internal
abstract interface class SwiftPmGatePlatform {
  SwiftPmArtifactFileSystem get fileSystem;
  bool matchesTarget<P extends PlatformHostInterface>(
    SwiftPmTargetPolicy<P> policy,
  );
  Future<String?> volumeIdentity(String path);
  Future<bool> createProofAlias(String alias, String target);
  Future<bool> verifyAlias(String alias, String target);
  Future<bool> probe({
    required SwiftPmGateMode mode,
    required String root,
    required String toolchainIdentity,
    required String sdkIdentity,
  });
}
