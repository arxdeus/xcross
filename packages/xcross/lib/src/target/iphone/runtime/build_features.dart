import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_iphone.dart';
import 'package:xcross/src/shared/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/shared/compose/toolchain/compose_toolchain_resolver.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';
import 'package:xcross/src/target/iphone/compose/iphone_compose_target.dart';
import 'package:xcross/src/target/iphone/flutter/iphone_flutter_target.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';
import 'package:xcross/src/target/shared/runtime/build_features.dart';

final class IPhoneBuildFeatures<T extends PlatformHostInterface>
    implements XcrossBuildFeatures<T> {
  IPhoneBuildFeatures(this.runtime) : target = IPhoneTarget(runtime.host);
  final XcrossRuntime<T> runtime;
  @override
  final IPhoneTarget<T> target;
  @override
  late final FlutterBuildRuntime<T> flutterRuntime = runtime.flutter.build(
    IPhoneFlutterTarget(target),
  );
  late final ComposeTarget<T> _composeTarget = IPhoneComposeTarget(
    target,
    runtime.composeHostProvider.resolve(),
  );
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
