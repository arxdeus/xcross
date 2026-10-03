import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';

typedef ComposeWhich =
    Future<String?> Function(
      String name, {
      Map<String, String>? environment,
      Iterable<String> extraDirectories,
    });
typedef ComposeRun =
    Future<ComposeProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

final class ComposeProcessResult {
  const ComposeProcessResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef CurrentDarwinSdk = ComposeDarwinSdk? Function(String? bundle);
typedef ResolveLd64Lld = Future<String> Function(ComposeDarwinSdk sdk);

abstract interface class ComposeDarwinSdk {
  String get swiftSdkPath;
  String iosSdk(IosBuildPlatformInterface platform);
}

final class RepositoryComposeDarwinSdk<T extends PlatformHostInterface>
    implements ComposeDarwinSdk {
  const RepositoryComposeDarwinSdk(this.sdk, this.repository);
  final DarwinSdk sdk;
  final DarwinSdkRepository<T> repository;
  @override
  String get swiftSdkPath => sdk.swiftSdkPath;
  @override
  String iosSdk(IosBuildPlatformInterface platform) =>
      repository.iosSdk(sdk, target: platform);
}
