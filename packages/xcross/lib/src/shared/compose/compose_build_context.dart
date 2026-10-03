import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

final class ComposeBuildContext<T extends PlatformHostInterface> {
  ComposeBuildContext({
    required this.target,
    required this.runner,
    required this.tools,
    required this.sdkRepository,
    required this.log,
    required this.downloader,
    this.cacheRoot,
    this.processorCount = 1,
  }) {
    if (!identical(target.host, target.toolchainHost.host) ||
        !identical(target.host, runner.host) ||
        !identical(target.host, tools.host) ||
        !identical(target.host, sdkRepository.host)) {
      throw ArgumentError(
        'Compose target, runner, SDK tools and Kotlin host must share one host instance.',
      );
    }
    if (!identical(log, runner.log) ||
        !identical(log, downloader.log) ||
        !identical(log, sdkRepository.log)) {
      throw ArgumentError('Compose effects must share one injected logger.');
    }
  }
  final ComposeTarget<T> target;
  final ProcessRunner<T> runner;
  final DarwinToolchainResolver<T> tools;
  final DarwinSdkRepository<T> sdkRepository;
  final Log log;
  final Downloader downloader;
  final String? cacheRoot;
  final int processorCount;
}
