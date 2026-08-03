import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/util/errors.dart';

/// `apt`-installable packages from the README Requirements table, plus the
/// Swift toolchain's own build dependencies. Swift and Flutter stay manual.
const _aptPackages = [
  'clang',
  'lld',
  'llvm',
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

    if (await _locate('ld64.lld') == null) {
      final linkers =
          Directory('/usr/bin')
              .listSync()
              .where(
                (entry) =>
                    (entry is File || entry is Link) &&
                    p.basename(entry.path).startsWith('ld64.lld-'),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      if (linkers.isNotEmpty) {
        await ProcessRunner.runChecked('sudo', [
          'ln',
          '-sf',
          linkers.last.path,
          '/usr/local/bin/ld64.lld',
        ], label: 'link ld64.lld');
      }
    }

    final missing = <String>[];
    for (final tool in const [
      'swift',
      'clang',
      'clang++',
      'llvm-ar',
      'ld64.lld',
    ]) {
      if (await _locate(tool) == null) missing.add(tool);
    }
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Linux requirements on PATH after apt install: '
        '${missing.join(', ')}.\n'
        'Install the Swift toolchain manually and ensure its bin directory is '
        'on PATH. The lld package must provide ld64.lld.',
      );
    }

    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
    Log.logDone('Requirements installed');
  }

  Future<void> _setupWindows() async {
    final missing = <String>[];
    for (final tool in const [
      'flutter',
      'swift',
      'clang',
      'clang++',
      'llvm-ar',
      'ld64.lld',
    ]) {
      if (await _locate(tool) == null) missing.add(tool);
    }
    if (missing.isNotEmpty) {
      throw XcrossError(
        'Missing Windows requirements on PATH: ${missing.join(', ')}.\n'
        'Install Flutter, Swift, and the official LLVM Windows toolchain, '
        'then retry.',
      );
    }
    if (!await Pymd.ensureInstalled()) {
      throw XcrossError('pymobiledevice3 install failed; see above.');
    }
    Log.logDone('Windows requirements found');
  }

  /// PATH lookup that refuses swiftly's `ld64.lld` shim — see
  /// [DarwinSdk.resolveLd64Lld] for why that one cannot link iOS.
  static Future<String?> _locate(String tool) => ProcessRunner.which(
    tool,
    accept: tool == 'ld64.lld' ? DarwinSdk.usableLd64Lld : null,
  );
}
