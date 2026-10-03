import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';

abstract interface class XcrunOperation {
  Future<int> run(List<String> arguments);
}

abstract interface class XcrunRuntimeLoader {
  Future<XcrunServices> loadXcrun({required String sdkName});
}

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
