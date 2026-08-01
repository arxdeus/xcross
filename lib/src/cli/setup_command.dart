import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:xcross/src/device/pymd.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/util/sudo.dart';

/// `apt`-installable packages from the README Requirements table, plus the
/// Swift toolchain's own build dependencies. Swift, `xtool`, Flutter, and the
/// Darwin SDK are not apt packages and stay manual.
const _aptPackages = [
  'clang',
  'python3',
  'python3-pip',
  'python3-venv',
  'usbmuxd',
  'usbutils',
  'libimobiledevice-utils',
  'linux-tools-common',
  'pkg-config',
  'zlib1g-dev',
  'libpython3-dev',
  'libstdc++-13-dev',
  'libxml2-dev',
  'libncurses-dev',
  'libz3-dev',
  'gnupg2',
  'libc6-dev',
  'libcurl4-openssl-dev',
  'libgcc-13-dev',
];

/// `xcross setup` — `sudo apt install` every apt-installable Requirement.
class SetupCommand extends Command<void> {
  @override
  String get name => 'setup';

  @override
  String get description => 'Install or verify host requirements';

  @override
  Future<void> run() async {
    if (Platform.isWindows) {
      await _setupWindows();
      return;
    }

    final apt = await ProcessRunner.which('apt-get');
    if (apt == null) {
      throw XcrossError(
        'apt-get not found; xcross setup only supports apt-based distros. '
        'Install manually:\n    sudo apt install ${_aptPackages.join(' ')}',
      );
    }

    await Sudo.cacheCredentials(
      manualHint:
          'Install manually:\n'
          '    sudo apt install ${_aptPackages.join(' ')}',
    );

    // Spinner with a streamed tail (not inheritStdio): apt's own progress
    // shows collapsed under the spinner. sudo -v above already cached the
    // credential, so this runs without a password prompt.
    final step = Log.beginStep('Installing apt requirements');
    try {
      await ProcessRunner.runChecked(
        'sudo',
        ['apt-get', 'install', '-y', ..._aptPackages],
        label: 'apt-get install',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }

    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
    Log.logDone('Requirements installed');
  }

  Future<void> _setupWindows() async {
    final missing = <String>[];
    for (final tool in const ['flutter', 'clang', 'ld64.lld']) {
      if (await ProcessRunner.which(tool) == null) missing.add(tool);
    }
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Windows requirements on PATH: ${missing.join(', ')}.\n'
        'Install Flutter and the official LLVM Windows toolchain, then retry.',
      );
    }
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
    Log.logDone('Windows requirements found');
  }
}
