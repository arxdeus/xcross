import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:pure/pure.dart';
import 'package:xcross/src/cli/basic/internal/linux_package_manager.dart';
import 'package:xcross/src/cli/basic/internal/swift_requirement.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/setup/setup_script.dart';

const _requiredTools = ['swift', 'clang', 'clang++', 'llvm-ar', 'ld64.lld'];

/// `xcross setup` — install host requirements through apt/dnf/pacman (Linux)
/// or Homebrew (macOS), then pipx and pymobiledevice3. On Windows, verifies
/// tools already on PATH and installs pymobiledevice3.
final class SetupCommand extends Command<void> {
  SetupCommand() {
    argParser.addFlag(
      _refreshScriptFlag,
      negatable: false,
      help: 'Refresh the cached remote setup script without executing it.',
    );
  }

  static const _refreshScriptFlag = 'refresh-script';

  @override
  String get name => 'setup';

  @override
  String get description => 'Install or verify host requirements';

  @override
  Future<void> run() async {
    final configuredScript = SetupScriptManager();
    if (argResults?[_refreshScriptFlag] as bool? ?? false) {
      if (configuredScript.isRemote) await configuredScript.refresh();
      return;
    }
    if (configuredScript.isConfigured) {
      await configuredScript.run();
      Log.logDone('Configured setup script completed');
      return;
    }
    await SwiftRequirement.require('set up this host');
    if (Platform.isWindows) return _setupWindows();
    if (Platform.isMacOS) return _setupMacos();
    return _setupLinux();
  }

  Future<void> _setupLinux() async {
    final manager = await _resolvePackageManager();

    await Sudo.cacheCredentials(manualHint: manager.manualHint());
    await _installPackages(manager);
    await _linkVersionedLd64Lld();

    final missing = await _missingTools(_requiredTools);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Linux requirements on PATH after ${manager.name} install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. The lld package must provide ld64.lld.',
      );
    }

    final pipx = await _ensurePipx(
      attempts: await _pipxInstallAttempts(manager),
      manualHint: manager.manualHint([manager.pipxPackage]),
    );
    await _ensurePymd();
    await _pipxEnsurePath(pipx);
    Log.logDone('Requirements installed');
  }

  Future<void> _setupMacos() async {
    if (await ProcessRunner.which('brew') == null) {
      throw XcrossError(
        'Homebrew is required for `xcross setup` on macOS.\n'
        'Install it from https://brew.sh and retry.',
      );
    }

    await _brewInstall(const ['lld', 'llvm']);

    final missing = await _missingTools(_requiredTools);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing macOS requirements after Homebrew install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. LLVM tools come from `brew install lld llvm`.',
      );
    }

    final pipx = await _ensurePipx(
      attempts: await _pipxInstallAttemptsMacos(),
      manualHint: 'Install manually:\n    brew install pipx',
    );
    await _ensurePymd();
    await _pipxEnsurePath(pipx);
    Log.logDone('Requirements installed');
  }

  Future<void> _setupWindows() async {
    final missing = await _missingTools(['flutter', ..._requiredTools]);
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Windows requirements on PATH: ${missing.join(', ')}.\n'
        'Install Flutter, Swift, and the official LLVM Windows toolchain, '
        'then retry.',
      );
    }
    await _ensurePymd();
    Log.logDone('Windows requirements found');
  }

  Future<void> _brewInstall(List<String> packages) async {
    final step = Log.beginStep('Installing Homebrew requirements');
    try {
      await ProcessRunner.runChecked(
        'brew',
        ['install', ...packages],
        label: 'brew install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// The package manager to drive: the detected one when it is unambiguous,
  /// otherwise the user's pick.
  static Future<LinuxPackageManager> _resolvePackageManager() async {
    final detected = await LinuxPackageManager.detect();
    if (detected.length == 1) {
      final only = detected.single;
      Log.logInfo('Package manager', only.name);
      return only;
    }

    final picked = detected.isEmpty
        ? _promptForPackageManager(
            LinuxPackageManager.values,
            'No supported package manager found on PATH '
            '(${LinuxPackageManager.values.map((m) => m.executable).join(', ')}'
            ').',
          )
        : _promptForPackageManager(
            detected,
            'Multiple package managers found on this host.',
          );

    if (await ProcessRunner.which(picked.executable) == null) {
      throw XcrossError(
        '${picked.executable} is not on PATH, so xcross cannot drive it.\n'
        '${picked.manualHint()}',
      );
    }
    return picked;
  }

  static LinuxPackageManager _promptForPackageManager(
    List<LinuxPackageManager> choices,
    String reason,
  ) {
    if (!stdin.hasTerminal) {
      throw XcrossError(
        '$reason\n'
        'Re-run `xcross setup` from a terminal to choose one, or install the '
        'requirements yourself:\n'
        '${choices.map((choice) => '    ${choice.manualHint()}').join('\n')}',
      );
    }

    stdout.writeln(reason);
    stdout.writeln('Which one should xcross use?');
    for (var i = 0; i < choices.length; i++) {
      stdout.writeln(
        '  [${i + 1}] ${choices[i].name} '
        '(${choices[i].executable})',
      );
    }
    while (true) {
      stdout.write('Choice (1-${choices.length}): ');
      final raw = stdin.readLineSync()?.trim();
      if (raw == null) {
        throw XcrossError('No package manager selected (stdin closed).');
      }
      final choice = int.tryParse(raw);
      if (choice != null && choice >= 1 && choice <= choices.length) {
        return choices[choice - 1];
      }
      stdout.writeln(
        'Invalid choice "$raw". Enter a number 1-${choices.length}.',
      );
    }
  }

  /// Spinner with a streamed tail (not inheritStdio): the package manager's
  /// own progress shows collapsed under the spinner. `sudo -v` already cached
  /// the credential, so this runs without a password prompt.
  Future<void> _installPackages(LinuxPackageManager manager) async {
    final step = Log.beginStep('Installing ${manager.name} requirements');
    try {
      await _runFirstWorking(
        await manager.installAttempts(manager.packages),
        label: '${manager.name} install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// Run [attempts] in order until one exits zero; rethrow the last failure.
  static Future<void> _runFirstWorking(
    List<List<String>> attempts, {
    required String label,
    Step? tail,
  }) async {
    for (var i = 0; i < attempts.length; i++) {
      final attempt = attempts[i];
      Log.logTrace('[$label] running: ${attempt.join(' ')}');
      try {
        await ProcessRunner.runChecked(
          attempt.first,
          attempt.sublist(1),
          label: label,
          tail: tail,
        );
        return;
      } on Object {
        if (i == attempts.length - 1) rethrow;
      }
    }
  }

  /// Some distros only ship `ld64.lld-<version>`; point a stable name at the
  /// newest one so the toolchain lookup finds it.
  Future<void> _linkVersionedLd64Lld() async {
    if (await ProcessRunner.which(
          'ld64.lld',
          accept: DarwinSdk.usableLd64Lld,
        ) !=
        null) {
      return;
    }

    final versioned =
        Directory('/usr/bin')
            .listSync()
            .where(
              (entry) =>
                  (entry is File || entry is Link) &&
                  p.basename(entry.path).startsWith('ld64.lld-'),
            )
            .toList()
          ..sort(compare((entry) => entry.path));
    if (versioned.isEmpty) return;

    await ProcessRunner.runChecked(await ProcessRunner.locateTool('sudo'), [
      'ln',
      '-sf',
      versioned.last.path,
      '/usr/local/bin/ld64.lld',
    ], label: 'link ld64.lld');
  }

  /// pipx is the only pip route left on PEP 668 distros, and it keeps
  /// pymobiledevice3 in its own venv. Prefer the host package manager; fall
  /// back to a `--user` pip install when that fails.
  static Future<String> _ensurePipx({
    required List<List<String>> attempts,
    required String manualHint,
  }) async {
    final existing = await Pymd.resolvePipx();
    if (existing != null) return existing;

    final step = Log.beginStep('Installing pipx');
    for (final attempt in attempts) {
      Log.logTrace('[pipx] running: ${attempt.join(' ')}');
      final result = await ProcessRunner.run(attempt.first, attempt.sublist(1));
      if (result.exitCode != 0) continue;
      final pipx = await Pymd.resolvePipx();
      if (pipx != null) {
        step.done();
        return pipx;
      }
    }

    step.fail();
    throw XcrossError('Could not install pipx.\n$manualHint');
  }

  static Future<List<List<String>>> _pipxInstallAttempts(
    LinuxPackageManager manager,
  ) async {
    final py = await ProcessRunner.which('python3') ?? 'python3';
    return <List<String>>[
      ...await manager.installAttempts([manager.pipxPackage]),
      [py, '-m', 'pip', 'install', '--user', '--break-system-packages', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', 'pipx'],
    ];
  }

  static Future<List<List<String>>> _pipxInstallAttemptsMacos() async {
    final py = await ProcessRunner.which('python3') ?? 'python3';
    return <List<String>>[
      ['brew', 'install', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', '--break-system-packages', 'pipx'],
      [py, '-m', 'pip', 'install', '--user', 'pipx'],
    ];
  }

  /// Appends pipx's bin directory to the shell profile so the freshly linked
  /// `pymobiledevice3` resolves in new shells. Never fatal: xcross itself
  /// looks in that directory regardless.
  static Future<void> _pipxEnsurePath(String pipx) async {
    try {
      await ProcessRunner.runChecked(pipx, [
        'ensurepath',
      ], label: 'pipx ensurepath');
    } on Object catch (error) {
      Log.logWarn('pipx ensurepath failed, add ~/.local/bin to PATH: $error');
    }
  }

  static Future<void> _ensurePymd() async {
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
  }

  static Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final tool in tools) {
      if (await _locate(tool) == null) missing.add(tool);
    }
    return missing;
  }

  /// PATH lookup that also reaches [DarwinSdk.llvmToolDirs] (Homebrew keg-only
  /// LLVM, Debian versioned prefixes) and refuses swiftly's `ld64.lld` shim —
  /// see [DarwinSdk.resolveLd64Lld] for why that one cannot link iOS.
  static Future<String?> _locate(String tool) => ProcessRunner.which(
    tool,
    accept: tool == 'ld64.lld' ? DarwinSdk.usableLd64Lld : null,
    extraDirectories: DarwinSdk.llvmToolDirs(),
  );
}
