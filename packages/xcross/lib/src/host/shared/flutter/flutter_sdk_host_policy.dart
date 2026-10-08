import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

@internal
abstract interface class FlutterSdkHostPolicy<T extends PlatformHostInterface> {
  Future<String> rootFromExecutable(String executable, ProcessRunner<T> runner);
}
