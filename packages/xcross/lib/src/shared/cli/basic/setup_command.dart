import 'package:args/command_runner.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/shared/cli/command_prompt.dart';
import 'package:xcross/src/shared/errors/errors.dart';
import 'package:xcross/src/shared/setup/setup_requirements.dart';
import 'package:xcross/src/shared/setup/setup_script.dart';
import 'package:xcross/src/shared/setup/setup_script_policy.dart';

/// `xcross setup` — install host requirements.
///
/// A setup script runs when the config names one (`setup:`), or by default
/// on Windows (`setup/<manager>.ps1` for the installed winget, Scoop or
/// Chocolatey, else `setup/direct.ps1`). Every script is shown by name, source and
/// SHA-256 and needs confirmation before it runs. Without a script, Linux
/// drives apt/dnf/pacman and macOS drives Homebrew in-process; both need
/// Swift on PATH first.
@internal
final class SetupCommand extends Command<void> {
  SetupCommand({
    required this.host,
    required this.createHttpClient,
    required ProcessRunner runner,
    required this.requirements,
    required this.scriptPolicy,
    required this.swiftInstallGuidance,
    required this.commandPrompt,
    this.minimumSwift,
    this.setupSource,
    SetupScriptExecute? executeScript,
  }) : processRunner = runner,
       _executeScript = executeScript {
    argParser
      ..addFlag(
        _refreshScriptFlag,
        negatable: false,
        help: 'Refresh the cached remote setup script without executing it.',
      )
      ..addFlag(
        _yesFlag,
        abbr: 'y',
        negatable: false,
        help:
            'Run the setup script, and every installer it asks about, '
            'without confirmation.',
      );
    final managers = scriptPolicy.supportedManagers;
    if (managers.isNotEmpty) {
      argParser.addOption(
        _managerOption,
        allowed: managers,
        help:
            'Package manager whose setup script to run. Defaults to the '
            'one installed, asking when there are several.',
      );
    }
  }

  final PlatformHostInterface host;
  final http.Client Function() createHttpClient;
  final ProcessRunner processRunner;
  final SetupRequirements requirements;
  final SetupScriptPolicy scriptPolicy;
  final String swiftInstallGuidance;
  final CommandPrompt commandPrompt;
  final (int, int)? minimumSwift;
  final String? setupSource;
  final SetupScriptExecute? _executeScript;

  static const _refreshScriptFlag = 'refresh-script';
  static const _yesFlag = 'yes';
  static const _managerOption = 'manager';

  @override
  String get name => 'setup';

  @override
  String get description => 'Install or verify host requirements';

  @override
  Future<void> run() async {
    final configured = setupSource;
    final source = configured ?? await _defaultSource();
    final script = SetupScriptManager(
      host: host,
      createHttpClient: createHttpClient,
      runner: processRunner,
      source: source,
      policy: scriptPolicy,
      execute: _executeScript,
    );
    if (argResults?[_refreshScriptFlag] as bool? ?? false) {
      if (script.isRemote) await script.refresh();
      return;
    }
    if (script.isConfigured) {
      final assumeYes = argResults?[_yesFlag] as bool? ?? false;
      final ran = await script.run(
        approve: (candidate) => _approve(candidate, assumeYes: assumeYes),
        assumeYes: assumeYes,
        // The built-in default follows the release it is pinned to; only a
        // user-configured script keeps the cache `xcross update` refreshes.
        refreshFirst: configured == null,
      );
      if (ran) {
        processRunner.log.logDone('Setup script completed');
      } else {
        processRunner.log.logWarn('Setup script not run; nothing was changed.');
      }
      return;
    }
    final swiftRequirement = SwiftRequirement(processRunner);
    final swift = await swiftRequirement.require(
      'set up this host',
      installGuidance: swiftInstallGuidance,
    );
    await swiftRequirement.requireMinimum(
      swift,
      minimumSwift,
      installGuidance: swiftInstallGuidance,
    );
    await requirements.run();
  }

  /// The built-in script for the requested or detected package manager, or
  /// null when this host has none.
  Future<String?> _defaultSource() async {
    final requested = argResults?.options.contains(_managerOption) ?? false
        ? argResults![_managerOption] as String?
        : null;
    if (requested != null) {
      final script = await scriptPolicy.sourceFor(requested);
      if (script == null) {
        throw XcrossError(
          '$requested is not installed on this host. Install it, or pick '
          'another with --manager '
          '(${scriptPolicy.supportedManagers.join(', ')}).',
        );
      }
      return script.source;
    }
    final available = await scriptPolicy.defaultSources();
    if (available.isEmpty) return null;
    if (available.length == 1 || !commandPrompt.isInteractive) {
      return available.first.source;
    }
    commandPrompt.write('Several package managers can set up this host:\n');
    for (var i = 0; i < available.length; i++) {
      commandPrompt.write('  [${i + 1}] ${available[i].manager}\n');
    }
    while (true) {
      final raw = commandPrompt.readLine(
        'Which one should xcross use? (1-${available.length}) ',
      );
      if (raw == null) {
        throw XcrossError('No package manager selected (stdin closed).');
      }
      final choice = int.tryParse(raw.trim());
      if (choice != null && choice >= 1 && choice <= available.length) {
        return available[choice - 1].source;
      }
      commandPrompt.write('Invalid choice "${raw.trim()}".\n');
    }
  }

  bool _approve(SetupScriptApproval script, {required bool assumeYes}) {
    final log = processRunner.log;
    log.logInfo('Setup script', script.name);
    log.logInfo('Source', script.source);
    if (script.path != script.source) log.logInfo('Cached at', script.path);
    log.logInfo('SHA-256', script.sha256);
    if (assumeYes) return true;
    if (!commandPrompt.isInteractive) {
      throw XcrossError(
        'xcross setup will not run ${script.name} without confirmation, and '
        'there is no terminal to ask.\n'
        'Review the script above, then re-run with `xcross setup --yes`.',
      );
    }
    final answer = commandPrompt
        .readLine('Run ${script.name} from ${script.source}? [y/N] ')
        ?.trim()
        .toLowerCase();
    return answer == 'y' || answer == 'yes';
  }
}
