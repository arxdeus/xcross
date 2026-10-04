import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/target/shared/ios_build_platform.dart';
import 'package:meta/meta.dart';

@internal
typedef ComposeWhich =
    Future<String?> Function(
      String name, {
      Map<String, String>? environment,
      Iterable<String> extraDirectories,
    });
@internal
typedef ComposeRun =
    Future<ComposeProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

@internal
final class ComposeProcessResult {
  const ComposeProcessResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
}

@internal
typedef CurrentDarwinSdk = ComposeDarwinSdk? Function(String? bundle);
@internal
typedef ResolveLd64Lld = Future<String> Function(ComposeDarwinSdk sdk);

@internal
abstract interface class ComposeDarwinSdk {
  String get swiftSdkPath;
  String iosSdk(IosBuildPlatformInterface platform);
}

@internal
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
