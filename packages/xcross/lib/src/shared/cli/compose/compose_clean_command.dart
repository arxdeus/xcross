import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/shared/clean_paths.dart';

/// `xcross compose clean` — remove xcross build output and caches for this
/// Compose Multiplatform project.
///
/// Gradle's own `build/` output and the shared Kotlin/Compose toolchain from
/// `xcross compose setup` are left alone.
@internal
final class ComposeCleanCommand extends Command<void> {
  ComposeCleanCommand({
    required this.host,
    required this.log,
    required this.projectRoot,
  });

  final PlatformHostInterface host;
  final Log log;
  final String projectRoot;

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Clear xcross build output and Kotlin/Native caches for this Compose '
      'project.';

  @override
  Future<void> run() async {
    CleanPaths(host, log).report(
      await cleanProject(),
      nothingFound: 'No xcross Compose build caches found',
    );
  }

  Future<List<String>> cleanProject() =>
      CleanPaths(host, log).delete(cachePaths(host, projectRoot));

  /// Project-local Compose build directories xcross owns under [projectRoot],
  /// for both the device and simulator targets.
  static List<String> cachePaths(
    PlatformHostInterface host,
    String projectRoot,
  ) {
    final paths = host.paths.context;
    return [
      // Device: framework copy, .app, konanc args, toolchain config, caches.
      paths.join(projectRoot, 'build', 'xcross-ios'),
      // Simulator: the same set plus its runners.
      paths.join(projectRoot, 'build', 'xcross-ios-simulator'),
      // Device Swift runner, generated runner sources, Swift module cache.
      paths.join(projectRoot, 'build', 'xcross-compose'),
      // Device Objective-C runner objects.
      paths.join(projectRoot, 'iosApp', '.build', 'runner'),
    ];
  }
}
