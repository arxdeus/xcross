import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/shared/clean_paths.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

/// `xcross flutter clean` — remove xcross build caches for this Flutter
/// project, keeping shared caches and unrelated build output.
@internal
final class FlutterCleanCommand extends Command<void> {
  FlutterCleanCommand({
    required this.log,
    required this.projectRoot,
    required this.policies,
    required this.environment,
  });

  final Log log;
  final String projectRoot;

  /// One policy per build target (device, simulator); each owns its own
  /// native-asset output and SwiftPM workspace.
  final List<FlutterTargetBuildPolicy> policies;
  final Map<String, String> environment;

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Clear xcross native asset and SwiftPM build caches for this Flutter '
      'project.';

  @override
  Future<void> run() async {
    final removed = await cleanProject(
      projectRoot,
      policies: policies,
      log: log,
      environment: environment,
    );
    CleanPaths(
      policies.first.target.host,
      log,
    ).report(removed, nothingFound: 'No xcross Flutter build caches found');
  }

  /// Project-local Flutter build caches xcross owns under [projectRoot].
  static List<String> cachePaths(
    String projectRoot, {
    required List<FlutterTargetBuildPolicy> policies,
    Map<String, String>? environment,
  }) {
    final paths = <String>{};
    for (final policy in policies) {
      final workspace = SwiftPmWorkspace.forProject(
        projectRoot,
        environment: environment,
        policy: policy,
      );
      paths
        ..add(policy.buildDirectory(projectRoot, 'xcross-native-assets'))
        ..add(workspace.root);
    }
    return paths.toList();
  }

  static Future<List<String>> cleanProject(
    String projectRoot, {
    required List<FlutterTargetBuildPolicy> policies,
    required Log log,
    Map<String, String>? environment,
  }) => CleanPaths(policies.first.target.host, log).delete(
    cachePaths(projectRoot, policies: policies, environment: environment),
  );
}
