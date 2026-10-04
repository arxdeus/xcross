import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/build/internal/swiftpm_workspace.dart';
import 'package:xcross/src/target/shared/flutter/flutter_target_build_policy.dart';

final class CleanCommand extends Command<void> {
  CleanCommand({
    required this.log,
    required this.projectRoot,
    required this.policy,
    required this.environment,
  });

  final Log log;
  final String projectRoot;
  final FlutterTargetBuildPolicy policy;
  final Map<String, String> environment;
  @override
  String get name => 'clean';

  @override
  String get description => 'Clear xcross build caches for this workspace.';

  @override
  Future<void> run() async {
    final removed = await cleanProject(
      projectRoot,
      policy: policy,
      environment: environment,
    );
    for (final path in removed) {
      log.logStatus('Removed $path');
    }
    return removed.isEmpty
        ? log.logStatus('No xcross build caches found')
        : log.logDone('Clean complete');
  }

  static Future<List<String>> cleanProject(
    String projectRoot, {
    required FlutterTargetBuildPolicy policy,
    Map<String, String>? environment,
  }) async {
    final workspace = SwiftPmWorkspace.forProject(
      projectRoot,
      environment: environment,
      policy: policy,
    );
    final paths = [
      policy.target.host.paths.context.join(
        projectRoot,
        'build',
        'xcross-native-assets',
      ),
      workspace.root,
    ];
    final removed = <String>[];
    for (final path in paths) {
      final directory = policy.target.host.fileSystem.directory(path);
      if (!directory.existsSync()) continue;
      await directory.delete(recursive: true);
      removed.add(path);
    }
    return removed;
  }
}
