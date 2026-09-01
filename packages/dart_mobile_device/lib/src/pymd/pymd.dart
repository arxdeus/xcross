import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:path/path.dart' as p;

/// Resolved pymobiledevice3 invocation — either the bare CLI or python3 -m.
class PymdInvocation {
  const PymdInvocation(this.executable, this.prefixArgs);
  final String executable;
  final List<String> prefixArgs;
}

/// The invocation to run `remote tunneld` with, and whether it satisfies
/// tunneld's real requirement of python >= 3.13.
///
/// The TCP tunnel protocol — the only one modern iOS still accepts (18.2+
/// removed QUIC) — needs python 3.13's native TLS-PSK API. On older pythons
/// pymobiledevice3 falls back to `sslpsk_pmd3`, which fails against current
/// OpenSSL with `SSL: NO_CIPHERS_AVAILABLE`, and tunneld logs that failure
/// at DEBUG level only: every wireless tunnel dies silently, forever.
class TunneldInvocation {
  const TunneldInvocation(this.invocation, {required this.modernPython});
  final PymdInvocation invocation;
  final bool modernPython;
}

/// One-shot invocations of `pymobiledevice3` for DVT ProcessControl,
/// RSD service discovery, and the installed-app list.
abstract final class Pymd {
  /// Coerce an `int` or parseable `String` port value into `int?`.
  static int? asPort(Object? value) => switch (value) {
    final int p => p,
    final String s => int.tryParse(s),
    _ => null,
  };

  static final _processLaunchedPidPattern = RegExp(
    r'Process launched with pid (\d+)',
  );
  static final _digitsPattern = RegExp(r'\d+');

  static PymdInvocation? _cached;
  static TunneldInvocation? _tunneldCached;

  static String get _installCommand => Platform.isWindows
      ? 'py -m pip install -U pymobiledevice3'
      : 'pipx install pymobiledevice3 && pipx ensurepath';

  /// Directories pipx links its entry points into.
  ///
  /// `pipx ensurepath` only edits shell profiles, so a process started before
  /// that (or by a shell that never sourced them) still has to look there
  /// itself.
  static List<String> get pipxBinDirectories {
    final env = Platform.environment;
    final configured = env['PIPX_BIN_DIR'];
    final home = env['HOME'] ?? env['USERPROFILE'];
    return [
      if (configured != null && configured.isNotEmpty) configured,
      if (home != null && home.isNotEmpty) p.join(home, '.local', 'bin'),
    ];
  }

  /// Human-readable install hint shown when pymobiledevice3 is not found.
  static String get _notFoundMessage =>
      'Could not find `pymobiledevice3` in PATH (or a Python 3 that can '
      '`import pymobiledevice3`).\n'
      'Install it once on this machine, e.g.:\n'
      '    $_installCommand';

  static Future<PymdInvocation> resolve() async {
    if (_cached != null) return _cached!;

    // Prefer the bare CLI when available.
    final cli = await ProcessRunner.which(
      'pymobiledevice3',
      extraDirectories: pipxBinDirectories,
    );
    if (cli != null) {
      _cached = PymdInvocation(cli, []);
      return _cached!;
    }

    // Fallback: Python launcher -m pymobiledevice3.
    final py = await _resolvePython();
    if (py == null) throw TunnelError(_notFoundMessage);

    final probe = await ProcessRunner.run(py, ['-c', 'import pymobiledevice3']);
    if (probe.exitCode != 0) throw TunnelError(_notFoundMessage);

    _cached = PymdInvocation(py, ['-m', 'pymobiledevice3']);
    return _cached!;
  }

  /// One-line probe: succeeds (printing the real interpreter path) only on
  /// a python that is both >= 3.13 and has pymobiledevice3 installed.
  /// `sys.executable` unwraps version-manager shims (mise, pyenv), whose
  /// shim scripts need the user's environment and would break under sudo.
  static const _modernPythonProbe =
      'import sys; '
      'assert sys.version_info >= (3, 13); '
      'import pymobiledevice3; '
      'print(sys.executable)';

  /// Resolve the invocation to run `remote tunneld` with.
  ///
  /// Prefers a python >= 3.13 that can import pymobiledevice3 — searched
  /// separately from [resolve], because the bare `pymobiledevice3` CLI (or
  /// launcher shims around it) may pin an older python that breaks only for
  /// tunneld's TCP tunnels. Falls back to the regular invocation with
  /// `modernPython: false` when no such python exists.
  static Future<TunneldInvocation> tunneldInvocation() async {
    if (_tunneldCached != null) return _tunneldCached!;
    for (final name in const [
      'python3.14',
      'python3.13',
      'python3',
      'python',
      'py',
    ]) {
      final candidate = await ProcessRunner.which(name);
      if (candidate == null) continue;
      try {
        final probe = await ProcessRunner.run(candidate, [
          '-c',
          _modernPythonProbe,
        ]);
        if (probe.exitCode != 0) continue;
        final real = probe.stdout.trim().split('\n').last.trim();
        if (real.isEmpty || !File(real).existsSync()) continue;
        return _tunneldCached = TunneldInvocation(
          PymdInvocation(real, const ['-m', 'pymobiledevice3']),
          modernPython: true,
        );
      } on Object {
        continue;
      }
    }
    return _tunneldCached = TunneldInvocation(
      await resolve(),
      modernPython: false,
    );
  }

  /// True if pymobiledevice3 is invocable (CLI on PATH, or importable by a
  /// python3 on PATH).
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

    final step = Log.beginStep('Installing pymobiledevice3 (one-time)');

    final py = await _resolvePython();
    if (py == null) {
      step.fail();
      Log.logError('no Python 3 found. Install Python 3 first.');
      return false;
    }

    for (final attempt in await _buildInstallAttempts(py)) {
      Log.logTrace('[python] running: ${attempt.join(' ')}');
      final result = await ProcessRunner.run(attempt[0], attempt.sublist(1));
      if (result.exitCode == 0) {
        _cached = null;
        if (await _isInstalled()) {
          step.done();
          return true;
        }
      }
    }

    step.fail();
    Log.logError(
      'failed to install pymobiledevice3. Install it manually:\n'
      '    $_installCommand',
    );
    return false;
  }

  static Future<String?> _resolvePython() async =>
      await ProcessRunner.which('python3') ??
      await ProcessRunner.which('python') ??
      await ProcessRunner.which('py');

  /// Absolute path to `pipx`, including the bin directory it installs into
  /// but may not have put on PATH yet.
  static Future<String?> resolvePipx() =>
      ProcessRunner.which('pipx', extraDirectories: pipxBinDirectories);

  /// Build the ordered list of install command vectors to try: pipx first (the
  /// only supported route on PEP 668 distros), then system-wide pip with
  /// `--break-system-packages`, then without, then the `--user` variants
  /// (which need no sudo).
  static Future<List<List<String>>> _buildInstallAttempts(String py) async {
    final sudo = await Sudo.resolve();
    final pipx = Platform.isWindows ? null : await resolvePipx();
    const pipInstall = ['-m', 'pip', 'install'];
    const upgradeTarget = ['-U', 'pymobiledevice3'];
    const breakSystem = '--break-system-packages';

    return <List<String>>[
      if (pipx != null) [pipx, 'install', 'pymobiledevice3'],
      if (sudo != null)
        [sudo, py, ...pipInstall, breakSystem, ...upgradeTarget],
      if (sudo != null) [sudo, py, ...pipInstall, ...upgradeTarget],
      [py, ...pipInstall, '--user', breakSystem, ...upgradeTarget],
      [py, ...pipInstall, '--user', ...upgradeTarget],
    ];
  }

  /// Launch [bundleId] suspended via DVT ProcessControl, returning the device
  /// PID.
  static Future<int> launchSuspended({
    required List<String> deviceArgs,
    required String bundleId,
    required List<String> appArguments,
  }) async {
    final joined = ProcessRunner.commandLine(bundleId, appArguments);
    final args = [
      'developer',
      'dvt',
      'launch',
      ...deviceArgs,
      '--suspended',
      '--kill-existing',
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
    throw TunnelError(
      'pymobiledevice3: expected "Process launched with pid <N>" in stdout, '
      'got: ${result.stdout}',
    );
  }

  /// Return set of installed bundle identifiers.
  ///
  /// [deviceArgs] selects the device (`--rsd <host> <port>`, `--tunnel
  /// <udid>`, or `--userspace --udid <udid>`); without it pymobiledevice3
  /// falls back to the first usbmux device, which does not exist for a
  /// wireless connection on Linux/Windows.
  ///
  /// pymobiledevice3 renamed the `--user`/`--system` filters to `--userspace`
  /// in newer releases (9.x); try the current flag first and fall back to the
  /// legacy flags so both versions work.
  static Future<List<String>> listInstalledApps({
    List<String> deviceArgs = const [],
  }) async {
    const attempts = <List<String>>[
      ['apps', 'list', '--type', 'User'],
      ['apps', 'list', '--userspace'],
      ['apps', 'list', '--user', '--system'],
    ];
    for (final args in attempts) {
      try {
        // Bounded per attempt: over a wireless tunnel a phone napping in
        // Wi-Fi power save can hang one RemoteXPC exchange for minutes, and
        // three unbounded attempts in a row would freeze the run silently.
        final result = await run([
          ...args,
          ...deviceArgs,
        ], timeout: const Duration(seconds: 45));
        if (jsonDecode(result.stdout) case final Map<Object?, Object?> json) {
          return json.keys.cast<String>().toList();
        }
      } on Object {
        // Try the next flag variant.
      }
    }
    throw TunnelError('pymobiledevice3 apps list: could not list apps');
  }

  /// Query RSD peer info and return the port of [service].
  static Future<int> rsdServicePort({
    required String rsdHost,
    required int rsdPort,
    required String service,
  }) async {
    final result = await run([
      'remote',
      'rsd-info',
      '--rsd',
      rsdHost,
      '$rsdPort',
    ]);
    final Object? root = jsonDecode(result.stdout);
    if (root is! Map) throw TunnelError('rsd-info: expected JSON object');

    final Object? services = root['Services'];
    final Object? entry = services is Map ? services[service] : null;
    if (entry is! Map) throw TunnelError('rsd-info: Services.$service missing');

    // Port can be String or int across pymobiledevice3 versions.
    final port = asPort(entry['Port']);
    if (port == null) {
      throw TunnelError('rsd-info: Services.$service.Port unparseable');
    }
    return port;
  }

  /// Return the device PID of [bundleId] if it is currently running, else null.
  /// Best-effort: returns null (rather than throwing) when the app isn't
  /// running or the query is unsupported.
  static Future<int?> processIdForBundleId({
    required List<String> deviceArgs,
    required String bundleId,
  }) async {
    final CapturedProcess result;
    try {
      // Bounded: this best-effort pre-install check rides the tunnel and
      // must not stall the run when the phone naps in Wi-Fi power save.
      result = await run([
        'developer',
        'dvt',
        'process-id-for-bundle-id',
        ...deviceArgs,
        bundleId,
      ], timeout: const Duration(seconds: 30));
    } on TunnelError {
      return null;
    }
    final pid = int.tryParse(
      _digitsPattern.firstMatch(result.stdout)?.group(0) ?? '',
    );
    // pymobiledevice3 prints `0` when the bundle id isn't running.
    return switch (pid) {
      null || 0 => null,
      _ => pid,
    };
  }

  /// Kill the process with device [pid] via DVT ProcessControl.
  static Future<void> killPid({
    required List<String> deviceArgs,
    required int pid,
  }) async {
    await run(['developer', 'dvt', 'kill', ...deviceArgs, '$pid']);
  }

  /// Run arbitrary pymobiledevice3 [args], returning captured output.
  /// Throws [TunnelError] on non-zero exit.
  ///
  /// [timeout] bounds the whole subprocess and kills it when exceeded —
  /// required for anything routed over a wireless tunnel, where a phone in
  /// Wi-Fi power save can stretch one RemoteXPC handshake past a minute.
  static Future<CapturedProcess> run(
    List<String> args, {
    Duration? timeout,
  }) async {
    final inv = await resolve();
    final executable = inv.executable;
    final arguments = [...inv.prefixArgs, ...args];
    Log.logTrace(
      '[pymobiledevice3] running: '
      '${ProcessRunner.commandLine(executable, arguments)}',
    );
    final result = timeout == null
        ? await ProcessRunner.run(
            executable,
            arguments,
            environment: usbmuxEnvironment(),
          )
        : await _runWithTimeout(executable, arguments, timeout);
    if (result.exitCode != 0) {
      final msg = result.stderr.isNotEmpty ? result.stderr : result.stdout;
      throw TunnelError(
        'pymobiledevice3 failed (exit ${result.exitCode}):\n$msg',
      );
    }
    return result;
  }

  /// [ProcessRunner.run], except the subprocess is killed when [timeout]
  /// passes (a plain `Future.timeout` would leak it, and a leaked
  /// pymobiledevice3 holding a tunnel connection keeps hanging around).
  static Future<CapturedProcess> _runWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final process = await ProcessRunner.start(
      executable,
      arguments,
      environment: usbmuxEnvironment(),
    );
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    try {
      await process.stdin.close();
    } catch (_) {}
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      // SIGTERM may be ignored mid-handshake; escalate shortly after.
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2)).then((_) {
          process.kill(ProcessSignal.sigkill);
        }),
      );
      throw TunnelError(
        'pymobiledevice3 ${arguments.join(' ')} timed out after '
        '${timeout.inSeconds}s',
      );
    }
    return CapturedProcess(exitCode, await stdout, await stderr);
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
    final addr = resolvedUsbmuxAddress();
    if (addr != null) env['USBMUXD_SOCKET_ADDRESS'] = addr;
    return env;
  }

  static String elevatedCommand(String arguments) =>
      '${Platform.isWindows ? '' : 'sudo '}pymobiledevice3 $arguments';

  /// `[sudo -n] [env USBMUXD_SOCKET_ADDRESS=…] <pymd> …args`.
  ///
  /// [invocation] overrides which pymobiledevice3 runs (tunneld needs a
  /// python the regular resolution may not pick).
  static Future<List<String>> elevatedArgs(
    List<String> pymdArgs, {
    PymdInvocation? invocation,
  }) async {
    final inv = invocation ?? await resolve();
    final sudo = await Sudo.resolve();
    final usbmux = resolvedUsbmuxAddress();
    return <String>[
      if (sudo != null) ...[sudo, '-n'],
      if (sudo != null && usbmux != null) ...[
        'env',
        'USBMUXD_SOCKET_ADDRESS=$usbmux',
      ],
      inv.executable,
      ...inv.prefixArgs,
      ...pymdArgs,
    ];
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
