import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';

@internal
final class PosixFlutterSdkPolicy<T extends PlatformHostInterface>
    implements FlutterSdkHostPolicy<T> {
  @override
  Future<String> rootFromExecutable(
    String executable,
    ProcessRunner<T> runner,
  ) async => runner.host.paths.context.dirname(
    runner.host.paths.context.dirname(executable),
  );
}
