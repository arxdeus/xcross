import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';
import 'package:xcross/src/util/process.dart';
import 'package:xcross/src/util/sudo.dart';

/// Resolved pymobiledevice3 invocation — either the bare CLI or python3 -m.
class PymdInvocation {
  const PymdInvocation(this.executable, this.prefixArgs);
  final String executable;
  final List<String> prefixArgs;

  List<String> args(List<String> extra) => [...prefixArgs, ...extra];
}

/// One-shot invocations of `pymobiledevice3` for DVT ProcessControl,
/// RSD service discovery, and the installed-app list.
abstract final class Pymd {
  static final _processLaunchedPidPattern =
      RegExp(r'Process launched with pid (\d+)');
  static final _digitsPattern = RegExp(r'\d+');

  static PymdInvocation? _cached;

  /// Human-readable install hint shown when pymobiledevice3 is not found.
  static const _notFoundMessage =
      'Could not find `pymobiledevice3` in PATH (or a python3 that can '
      '`import pymobiledevice3`).\n'
      'Install it once on this machine, e.g.:\n'
      '    sudo pip3 install --break-system-packages pymobiledevice3';

  static Future<PymdInvocation> resolve() async {
    if (_cached != null) return _cached!;

    // Prefer the bare CLI when available.
    final cli = await which('pymobiledevice3');
    if (cli != null) {
      _cached = PymdInvocation(cli, []);
      return _cached!;
    }

    // Fallback: python3 -m pymobiledevice3.
    final py = await which('python3') ?? await which('python');
    if (py == null) throw XcrossError(_notFoundMessage);

    final probe = await ProcessRunner.run(py, ['-c', 'import pymobiledevice3']);
    if (probe.exitCode != 0) throw XcrossError(_notFoundMessage);

    _cached = PymdInvocation(py, ['-m', 'pymobiledevice3']);
    return _cached!;
  }

  /// True if pymobiledevice3 is invocable (CLI on PATH or importable by python3).
  static Future<bool> _isInstalled() async {
    try {
      await resolve();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Ensure pymobiledevice3 is installed; install system-wide if missing.
  /// Returns true if available after the call.
  static Future<bool> ensureInstalled() async {
    if (await _isInstalled()) return true;

    logStatus('[pymobiledevice3] not found — installing (one-time)…');

    final py = await which('python3') ?? await which('python');
    if (py == null) {
      logError('no python3 found. Install Python 3 first.');
      return false;
    }

    for (final attempt in await _buildInstallAttempts(py)) {
      logStatus('[python] running: ${attempt.join(' ')}');
      final result = await Process.run(
        attempt[0],
        attempt.sublist(1),
        stderrEncoding: utf8,
        stdoutEncoding: utf8,
      );
      if (result.exitCode == 0) {
        _cached = null;
        if (await _isInstalled()) {
          logStatus('[pymobiledevice3] installed ✓');
          return true;
        }
      }
    }

    logError(
      'failed to install pymobiledevice3. Install it manually:\n'
      '    sudo pip3 install --break-system-packages pymobiledevice3',
    );
    return false;
  }

  /// Build the ordered list of install command vectors to try.
  static Future<List<List<String>>> _buildInstallAttempts(String py) async {
    final sudo = await Sudo.resolve();

    // Base pip-install arg vectors (without a leading sudo/py prefix).
    // Tried in order: system-wide with --break-system-packages, then without,
    // then --user variants (no sudo needed).
    const pipInstallBreak = [
      '-m', 'pip', 'install', '--break-system-packages', '-U',
      'pymobiledevice3', // ignore: lines_longer_than_80_chars
    ];
    const pipInstall = ['-m', 'pip', 'install', '-U', 'pymobiledevice3'];
    const pipInstallUserBreak = [
      '-m', 'pip', 'install', '--user', '--break-system-packages', '-U',
      'pymobiledevice3', // ignore: lines_longer_than_80_chars
    ];
    const pipInstallUser = [
      '-m',
      'pip',
      'install',
      '--user',
      '-U',
      'pymobiledevice3',
    ];

    return <List<String>>[
      if (sudo != null) [sudo, py, ...pipInstallBreak],
      if (sudo != null) [sudo, py, ...pipInstall],
      [py, ...pipInstallUserBreak],
      [py, ...pipInstallUser],
    ];
  }

  /// Launch [bundleId] suspended via DVT ProcessControl, returning the device PID.
  static Future<int> launchSuspended({
    required String rsdHost,
    required int rsdPort,
    required String bundleId,
    required List<String> appArguments,
    bool killExisting = true,
  }) async {
    final joined = ProcessRunner.commandLine(bundleId, appArguments);
    final args = [
      'developer',
      'dvt',
      'launch',
      '--rsd',
      rsdHost,
      '$rsdPort',
      '--suspended',
      if (killExisting) '--kill-existing',
      '--',
      joined,
    ];
    final result = await run(args);
    // stdout line: "Process launched with pid 12345"
    final match = _processLaunchedPidPattern.firstMatch(result.stdout);
    if (match != null) {
      final pid = int.tryParse(match.group(1)!);
      if (pid != null) return pid;
    }
    throw XcrossError(
      'pymobiledevice3: expected "Process launched with pid <N>" in stdout, '
      'got: ${result.stdout}',
    );
  }

  /// Return set of installed bundle identifiers.
  ///
  /// pymobiledevice3 renamed the `--user`/`--system` filters to `--userspace`
  /// in newer releases (9.x); try the current flag first and fall back to the
  /// legacy flags so both versions work.
  static Future<List<String>> listInstalledApps() async {
    const attempts = <List<String>>[
      ['apps', 'list', '--userspace'],
      ['apps', 'list', '--user', '--system'],
    ];
    for (final args in attempts) {
      try {
        final result = await run(args);
        final dynamic json = jsonDecode(result.stdout);
        if (json is Map) return json.keys.cast<String>().toList();
      } on Object {
        // Try the next flag variant.
      }
    }
    throw XcrossError('pymobiledevice3 apps list: could not list apps');
  }

  /// Query RSD peer info and return the port of [service].
  static Future<int> rsdServicePort({
    required String rsdHost,
    required int rsdPort,
    required String service,
  }) async {
    final result =
        await run(['remote', 'rsd-info', '--rsd', rsdHost, '$rsdPort']);
    final dynamic root = jsonDecode(result.stdout);
    if (root is! Map) throw XcrossError('rsd-info: expected JSON object');
    final services = root['Services'];
    if (services is! Map) {
      throw XcrossError('rsd-info: Services.$service missing');
    }
    final entry = services[service];
    if (entry is! Map) throw XcrossError('rsd-info: Services.$service missing');

    // Port can be String or int across pymobiledevice3 versions.
    final port = switch (entry['Port']) {
      final int p => p,
      final String s => int.tryParse(s),
      _ => null,
    };
    if (port != null) return port;
    throw XcrossError('rsd-info: Services.$service.Port unparseable');
  }

  /// Return the device PID of [bundleId] if it is currently running, else null.
  /// Best-effort: returns null (rather than throwing) when the app isn't
  /// running or the query is unsupported.
  static Future<int?> processIdForBundleId({
    required String rsdHost,
    required int rsdPort,
    required String bundleId,
  }) async {
    final CapturedProcess result;
    try {
      result = await run([
        'developer',
        'dvt',
        'process-id-for-bundle-id',
        '--rsd',
        rsdHost,
        '$rsdPort',
        bundleId,
      ]);
    } on XcrossError {
      return null;
    }
    final pid =
        int.tryParse(_digitsPattern.firstMatch(result.stdout)?.group(0) ?? '');
    // pymobiledevice3 prints `0` when the bundle id isn't running.
    return switch (pid) { null || 0 => null, _ => pid };
  }

  /// Kill the process with device [pid] via DVT ProcessControl.
  static Future<void> killPid({
    required String rsdHost,
    required int rsdPort,
    required int pid,
  }) async {
    await run(
        ['developer', 'dvt', 'kill', '--rsd', rsdHost, '$rsdPort', '$pid']);
  }

  /// Run arbitrary pymobiledevice3 [args], returning captured output.
  /// Throws [XcrossError] on non-zero exit.
  static Future<CapturedProcess> run(List<String> args) async {
    final inv = await resolve();
    final executable = inv.executable;
    final arguments = inv.args(args);
    logStatus(
      '[pymobiledevice3] running: ${ProcessRunner.commandLine(executable, arguments)}',
    );
    final result = await ProcessRunner.run(
      executable,
      arguments,
      environment: usbmuxEnvironment(),
    );
    if (result.exitCode != 0) {
      final msg = result.stderr.isNotEmpty ? result.stderr : result.stdout;
      throw XcrossError(
          'pymobiledevice3 failed (exit ${result.exitCode}):\n$msg');
    }
    return result;
  }

  /// Env for child pymobiledevice3 processes.
  ///
  /// On Linux, pymobiledevice3 defaults to TCP `127.0.0.1:27015` (Apple Mobile
  /// Device Service). With usbipd that port is closed, so point at the local
  /// unix socket when it exists and the caller hasn't set the env already.
  static Map<String, String> usbmuxEnvironment() {
    final env = Map<String, String>.from(Platform.environment);
    final existing = env['USBMUXD_SOCKET_ADDRESS'];
    if (existing != null && existing.isNotEmpty) return env;
    const unix = '/var/run/usbmuxd';
    if (File(unix).existsSync()) {
      env['USBMUXD_SOCKET_ADDRESS'] = unix;
    }
    return env;
  }

  /// Absolute usbmux address to pass through `sudo env …` (never empty).
  static String? resolvedUsbmuxAddress() {
    final fromEnv = Platform.environment['USBMUXD_SOCKET_ADDRESS'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    const unix = '/var/run/usbmuxd';
    if (File(unix).existsSync()) return unix;
    return null;
  }
}
