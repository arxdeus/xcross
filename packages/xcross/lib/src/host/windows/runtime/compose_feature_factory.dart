import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/compose/compose.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/runtime/compose_feature_factory.dart';

final class WindowsComposeFeatureFactory<T extends WindowsHostInterface>
    implements ComposeFeatureFactory<T> {
  const WindowsComposeFeatureFactory(
    this.host,
    this.runner,
    this.runningExecutable,
  );
  final String runningExecutable;
  final T host;
  final ProcessRunner<T> runner;
  @override
  ComposeTarget<T> iphone(IPhoneTargetInterface<T> target) =>
      IPhoneComposeTarget(
        target,
        WindowsComposeHost(host, runningExecutable: runningExecutable),
      );
  @override
  ComposeTarget<T> simulator(SimulatorTargetInterface<T> target) =>
      throw XcrossError(
        'Compose iOS simulator builds are supported only on macOS.',
      );
}
