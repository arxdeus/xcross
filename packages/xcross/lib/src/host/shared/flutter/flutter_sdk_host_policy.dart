import 'package:cli_kit/cli_kit_shared.dart';

abstract interface class FlutterSdkHostPolicy<T extends PlatformHostInterface> {
  Future<String> rootFromExecutable(String executable, ProcessRunner<T> runner);
}
