import 'dart:io';

import 'package:xcross/src/models/device/device.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';

/// Which devices `xtool` should search for.
enum DeviceSearchMode {
  all,
  usb,
  wifi;

  String? get flag => switch (this) {
        DeviceSearchMode.usb => '--usb',
        // Upstream xtool's SearchMode flag is `--network` (not `--wifi`).
        DeviceSearchMode.wifi => '--network',
        DeviceSearchMode.all => null,
      };
}

/// Wrapper around the original (upstream) `xtool` binary. xcross delegates the
/// generic iOS concerns — device discovery, code-signing, and install — to
/// these commands, and re-implements only the Flutter-specific build and the
/// iOS 17+ launch/hot-reload pipeline itself.
class XtoolCli {
  XtoolCli({this.executable = 'xtool'});

  /// Path to (or name of) the `xtool` binary on PATH.
  final String executable;

  /// `xtool devices [--usb|--wifi] --no-wait`.
  ///
  /// Output format is one device per line: `Name [usb]: <udid>`.
  Future<List<Device>> devices({
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final args = <String>['devices'];
    final flag = mode.flag;
    if (flag != null) args.add(flag);
    args.add('--no-wait');
    final result = await ProcessRunner.run(executable, args);
    if (result.exitCode != 0) {
      throw XcrossError('`xtool devices` failed:\n${result.stderr}');
    }
    return parseDevices(result.stdout);
  }

  static final RegExp _deviceLine = RegExp(r'^(.+) \[(\w+)\]:\s*(\S+)$');
  static final RegExp _newlinePattern = RegExp(r'\r?\n');

  /// Parse the plain-text output of `xtool devices`.
  static List<Device> parseDevices(String output) {
    final devices = <Device>[];
    for (final line in output.split(_newlinePattern)) {
      final match = _deviceLine.firstMatch(line.trim());
      if (match == null) continue;
      devices.add(Device(
        name: match.group(1)!.trim(),
        type: ConnectionType.parse(match.group(2)!),
        udid: match.group(3)!,
      ));
    }
    return devices;
  }

  /// Resolve a single target device.
  ///
  /// If [selector] is given it must match a connected device by UDID or name
  /// (flutter's `-d/--device-id` accepts either). Otherwise, if exactly one
  /// device is connected it is used; if several are connected and stdin is a
  /// TTY, an interactive numbered picker is shown; on non-TTY (CI, piped)
  /// stdin, an error listing the candidates is thrown so the caller can pass
  /// `--udid`/`-d` to disambiguate.
  Future<Device> resolveDevice({
    String? selector,
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final list = await devices(mode: mode);
    if (selector != null) {
      final match = list.where((d) => d.udid == selector || d.name == selector);
      if (match.isEmpty) {
        throw XcrossError('No connected device matching "$selector".');
      }
      return match.first;
    }
    if (list.isEmpty) {
      throw XcrossError(
        'No devices connected. Connect an iPhone (and tap Trust), then retry.',
      );
    }
    if (list.length == 1) return list.first;
    return _pickDeviceInteractively(list);
  }

  /// Prompt the user to pick a device from [list].
  ///
  /// Falls back to an [XcrossError] when stdin is not a TTY (e.g. CI, piped
  /// input) so scripts fail fast instead of hanging on a prompt.
  Device _pickDeviceInteractively(List<Device> list) {
    if (!stdin.hasTerminal) {
      final names = list.map((d) => '  $d').join('\n');
      throw XcrossError(
        'Multiple devices connected; pass --udid to choose one:\n$names',
      );
    }

    stdout.writeln('Multiple devices connected. Choose one:');
    for (var i = 0; i < list.length; i++) {
      stdout.writeln('  [${i + 1}] ${list[i]}');
    }

    // Save stdin terminal modes before touching them. On some platforms
    // (Linux /dev/null, Windows without a conhost) reading echoMode / lineMode
    // throws; _tryGet swallows that and returns null so the finally block
    // skips the restore rather than throwing a second error.
    final priorEcho = _tryGet(() => stdin.echoMode);
    final priorLine = _tryGet(() => stdin.lineMode);
    try {
      _trySet(() => stdin.echoMode = true);
      _trySet(() => stdin.lineMode = true);

      while (true) {
        stdout.write('Choice (1-${list.length}): ');
        final raw = stdin.readLineSync()?.trim();
        if (raw == null) {
          throw XcrossError('No selection made (stdin closed).');
        }
        final n = int.tryParse(raw);
        if (n != null && n >= 1 && n <= list.length) {
          return list[n - 1];
        }
        stdout
            .writeln('Invalid choice "$raw". Enter a number 1-${list.length}.');
      }
    } finally {
      if (priorEcho != null) _trySet(() => stdin.echoMode = priorEcho);
      if (priorLine != null) _trySet(() => stdin.lineMode = priorLine);
    }
  }

  static T? _tryGet<T>(T Function() f) {
    try {
      return f();
    } catch (_) {
      return null;
    }
  }

  static void _trySet(void Function() f) {
    try {
      f();
    } catch (_) {}
  }

  /// `xtool install <path> [--udid <udid>] [--usb|--wifi]`.
  ///
  /// Signs (using saved `xtool auth` credentials) and installs a `.app` or
  /// `.ipa`. Runs under a spinner whose grey tail shows xtool's own progress;
  /// stdin is forwarded so interactive prompts (e.g. certificate revocation)
  /// still work.
  Future<void> install(
    String appOrIpaPath, {
    String? udid,
    DeviceSearchMode mode = DeviceSearchMode.all,
  }) async {
    final args = <String>['install', appOrIpaPath];
    if (udid != null) args.addAll(['--udid', udid]);
    final flag = mode.flag;
    if (flag != null) args.add(flag);

    final step = Log.beginStep('Signing and installing');
    try {
      await ProcessRunner.runChecked(
        executable,
        args,
        label: 'xtool',
        tail: step,
      );
      step.done();
    } on Object {
      step.fail();
      rethrow;
    }
  }

  /// `xtool launch <bundleID> [args...] [--udid <udid>]`.
  ///
  /// Used for the pre-iOS-17 debugserver launch path (launch + detach).
  Future<void> launch(
    String bundleId, {
    String? udid,
    List<String> args = const [],
  }) async {
    final cmd = <String>['launch', bundleId, ...args];
    if (udid != null) cmd.addAll(['--udid', udid]);
    await ProcessRunner.runChecked(
      executable,
      cmd,
      inheritStdio: true,
      label: 'xtool',
    );
  }
}
