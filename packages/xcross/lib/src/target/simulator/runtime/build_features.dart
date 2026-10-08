import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:darwin_sdk_kit/target/simulator/simulator_target.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';
import 'package:xcross/src/target/simulator/compose/simulator_compose_target.dart';
import 'package:xcross/src/target/simulator/flutter/simulator_flutter_target.dart';

@internal
final class SimulatorBuildFeatures<T extends PlatformHostInterface>
    implements XcrossBuildFeatures<T> {
  SimulatorBuildFeatures(this.runtime) : target = SimulatorTarget(runtime.host);
  final XcrossRuntime<T> runtime;
  @override
  final SimulatorTarget<T> target;
  @override
  late final FlutterBuildRuntime<T> flutterRuntime = runtime.flutter.build(
    SimulatorFlutterTarget(target),
  );
  late final ComposeTarget<T> _composeTarget = _resolveComposeTarget();
  ComposeTarget<T> _resolveComposeTarget() {
    final signing = runtime.composeSimulatorCapability.requireSigning();
    return SimulatorComposeTarget(
      target,
      runtime.composeHostProvider.resolve(),
      signing: signing,
    );
  }

  @override
  late final ComposePackOperation<T> composeOperation = ComposePackOperation(
    _composeTarget,
    runner: runtime.runner,
    downloader: runtime.downloader,
    processorCount: runtime.processorCount,
    log: runtime.log,
    tools: runtime.darwinToolchain,
    sdkRepository: runtime.sdkRepository,
    cacheRoot: runtime.config.roots?.konanData,
  );
  @override
  late final ComposeToolchainResolver<T> composeResolver =
      ComposeToolchainResolver(
        _composeTarget,
        runner: runtime.runner,
        downloader: runtime.downloader,
        log: runtime.log,
        tools: runtime.darwinToolchain,
        sdkRepository: runtime.sdkRepository,
        cacheRoot: runtime.config.roots?.konanData,
      );
}
