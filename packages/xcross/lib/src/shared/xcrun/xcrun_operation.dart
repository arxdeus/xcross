import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class XcrunOperation {
  Future<int> run(List<String> arguments);
}

@internal
abstract interface class XcrunRuntimeLoader {
  Future<XcrunServices> loadXcrun({required String sdkName});
}

@internal
final class XcrunServices {
  const XcrunServices({
    required this.runner,
    required this.repository,
    required this.toolchain,
    required this.normalizeExecutable,
    required this.target,
  });
  final IosBuildPlatformInterface target;
  final ProcessRunner runner;
  final DarwinSdkRepository repository;
  final DarwinToolchainResolver toolchain;
  final String Function(String) normalizeExecutable;
}
