import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/setup/setup_script.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

/// `xcross setup` — install host requirements through apt/dnf/pacman (Linux)
/// or Homebrew (macOS), then pipx and pymobiledevice3. On Windows, verifies
/// tools already on PATH and installs pymobiledevice3.
@internal
final class SetupCommand extends Command<void> {
  SetupCommand({
    required this.host,
    required this.createHttpClient,
    required ProcessRunner runner,
    required this.requirements,
    required this.scriptPolicy,
    required this.swiftInstallGuidance,
    this.setupSource,
  }) : processRunner = runner {
    argParser.addFlag(
      _refreshScriptFlag,
      negatable: false,
      help: 'Refresh the cached remote setup script without executing it.',
    );
  }

  final PlatformHostInterface host;
  final http.Client Function() createHttpClient;
  final ProcessRunner processRunner;
  final SetupRequirements requirements;
  final SetupScriptPolicy scriptPolicy;
  final String swiftInstallGuidance;
  final String? setupSource;

  static const _refreshScriptFlag = 'refresh-script';

  @override
  String get name => 'setup';

  @override
  String get description => 'Install or verify host requirements';

  @override
  Future<void> run() async {
    final configuredScript = SetupScriptManager(
      host: host,
      createHttpClient: createHttpClient,
      runner: processRunner,
      source: setupSource,
      policy: scriptPolicy,
    );
    if (argResults?[_refreshScriptFlag] as bool? ?? false) {
      if (configuredScript.isRemote) await configuredScript.refresh();
      return;
    }
    if (configuredScript.isConfigured) {
      await configuredScript.run();
      processRunner.log.logDone('Configured setup script completed');
      return;
    }
    await SwiftRequirement(
      processRunner,
    ).require('set up this host', installGuidance: swiftInstallGuidance);
    await requirements.run();
  }
}
