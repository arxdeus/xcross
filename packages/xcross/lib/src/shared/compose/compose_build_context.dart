import 'package:cli_kit/shared/download/download.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:darwin_sdk_kit/shared/sdk/darwin_sdk_repository.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/target/shared/compose/compose_target.dart';

@internal
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
