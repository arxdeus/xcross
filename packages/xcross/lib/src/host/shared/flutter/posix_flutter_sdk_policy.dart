import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/shared/flutter/flutter_sdk_host_policy.dart';

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
