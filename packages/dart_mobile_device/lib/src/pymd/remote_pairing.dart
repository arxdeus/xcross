import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Device-initiated wireless pairing (`pymobiledevice3 remote pair-host`)
/// and the remote pairing records both pairing flows produce.
///
/// tunneld's Wi-Fi monitor can only connect to phones it has a record for
/// (`~/.pymobiledevice3/remote_<UDID>.plist`), so "no record" is the signal
/// that pairing has to happen before any wireless discovery can succeed.
abstract final class RemotePairing {
  /// How long the pair-host advertisement waits for the user to complete
  /// pairing on the phone before giving up.
  static const Duration pairHostTimeout = Duration(minutes: 3);

  /// Name advertised on the phone, `xcross-` prefixed so the entry is
  /// recognizable among real Macs in Settings > Developer > Paired Macs.
  static String get advertiseName {
    final host = Platform.localHostname;
    return host.startsWith('xcross-') ? host : 'xcross-$host';
  }

  /// Test override for [homeFolder].
  @visibleForTesting
  static String? homeOverride;

  /// pymobiledevice3's home folder (`~/.pymobiledevice3`), where remote
  /// pairing records live. Mirrors upstream `get_home_folder()`.
  static String get homeFolder {
    final override = homeOverride;
    if (override != null) return override;
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'] ?? '.';
    return p.join(home, '.pymobiledevice3');
  }

  /// Device identifiers with a remote pairing record on this host
  /// (`remote_<UDID>.plist`).
  static List<String> pairingRecordIds() {
    final dir = Directory(homeFolder);
    if (!dir.existsSync()) return const [];
    final ids = <String>[];
    for (final entry in dir.listSync()) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      if (!name.startsWith('remote_')) continue;
      final id = name.substring('remote_'.length).split('.').first;
      if (id.isNotEmpty) ids.add(id);
    }
    return ids;
  }

  /// Whether device-initiated pairing is worth offering for [selector].
  ///
  /// True when this host has no remote pairing record that could plausibly
  /// belong to the requested phone: no records at all, or a UDID selector
  /// that matches none of them. A device-name selector cannot be matched
  /// against records (they only store UDIDs), so any existing record is
  /// assumed to be the phone in question — re-advertising to an
  /// already-paired phone is useless, since it silently ignores a host it
  /// knows instead of showing it under "Other Devices".
  static bool shouldOfferPairing([String? selector]) {
    final records = pairingRecordIds();
    if (records.isEmpty) return true;
    if (selector != null && looksLikeUdid(selector)) {
      final wanted = _normalize(selector);
      return !records.any((id) => _normalize(id) == wanted);
    }
    return false;
  }

  /// Whether [selector] is UDID-shaped (hex with optional dashes) rather
  /// than a device name.
  @visibleForTesting
  static bool looksLikeUdid(String selector) {
    final bare = selector.replaceAll('-', '');
    return bare.length >= 24 && _hexPattern.hasMatch(bare);
  }

  static final _hexPattern = RegExp(r'^[0-9A-Fa-f]+$');

  static String _normalize(String id) => id.replaceAll('-', '').toUpperCase();

  /// Advertise this host for device-initiated pairing and block until the
  /// user completes it on the phone (or [timeout] passes). Returns whether a
  /// pairing record was created.
  static Future<bool> advertisePairHost({
    Duration timeout = pairHostTimeout,
  }) async {
    final process = await startPairHost(timeout: timeout);
    if (process == null) return false;
    return await process.exitCode == 0;
  }

  /// Start the pair-host advertisement as a child process the caller owns,
  /// or null when it cannot run (pymobiledevice3 missing or too old).
  ///
  /// Runs `pymobiledevice3 remote pair-host`. By default with inherited
  /// stdio: it prints the on-phone steps and the 6-digit code the user must
  /// type, so its output must reach the terminal verbatim. With [onLine] the
  /// process runs piped instead and every output line is forwarded — for
  /// running the advertisement *in the background* of other steps whose
  /// spinners inherited stdio would corrupt. No root needed either way.
  ///
  /// Callers that can detect the phone connecting by other means (tunneld
  /// reusing a still-valid record) should kill the process the moment it
  /// does.
  ///
  /// [fresh] advertises a random host identifier instead of this machine's
  /// deterministic one, forcing pair-*setup* (which shows a PIN) even when
  /// the phone still lists a stale entry for this host. Requires the bundled
  /// runner script; falls back to the plain CLI when it is unavailable.
  static Future<Process?> startPairHost({
    Duration timeout = pairHostTimeout,
    void Function(String line)? onLine,
    bool fresh = false,
  }) async {
    final PymdInvocation inv;
    try {
      inv = await Pymd.resolve();
    } on Object {
      return null;
    }
    if (fresh) {
      final process = await _startFreshPairHost(timeout: timeout);
      if (process != null) {
        if (onLine != null) _pipeLines(process, onLine);
        return process;
      }
      Log.logTrace('fresh pair-host runner unavailable; using the plain CLI');
    }
    if (!await _supportsPairHost()) {
      Log.logWarn(
        'this pymobiledevice3 has no `remote pair-host` command — update it '
        '(e.g. `pipx upgrade pymobiledevice3`) to pair from the phone, or '
        'pair over USB instead.',
      );
      return null;
    }

    if (onLine == null) {
      Log.logWarn(
        'Device-initiated pairing requires iOS 27 or later. On older iOS, '
        'plug the phone in over USB once and re-run with --wifi, or run '
        '`pymobiledevice3 remote pair`.\n'
        'If this host was paired before, remove it on the phone first '
        '(Settings > Developer > Paired Macs), or it will not reappear.',
      );
      // The subprocess owns the terminal: it prints the pairing steps, the
      // PIN, and a waiting heartbeat. Any spinner would corrupt that.
      Log.stopStep();
    }
    try {
      final process = await Process.start(
        inv.executable,
        [
          ...inv.prefixArgs,
          'remote',
          'pair-host',
          '--name',
          advertiseName,
          '--timeout',
          '${timeout.inSeconds}',
        ],
        // PYTHONUNBUFFERED: with piped stdio python block-buffers stdout, so
        // the 6-digit code would sit invisible in a 4 KB buffer until exit —
        // the one line the whole flow exists to show.
        environment: {...Pymd.usbmuxEnvironment(), 'PYTHONUNBUFFERED': '1'},
        mode: onLine == null
            ? ProcessStartMode.inheritStdio
            : ProcessStartMode.normal,
      );
      if (onLine != null) {
        _pipeLines(process, onLine);
      }
      return process;
    } on Object catch (e) {
      Log.logWarn('could not start `pymobiledevice3 remote pair-host`: $e');
      return null;
    }
  }

  /// Forward both output streams of [process] to [onLine], one line at a
  /// time, and close its stdin (it never reads any).
  static void _pipeLines(Process process, void Function(String) onLine) {
    try {
      unawaited(process.stdin.close().catchError((Object _) {}));
    } catch (_) {}
    for (final stream in [process.stdout, process.stderr]) {
      stream
          // Lossy on purpose: a strict decoder would drop a whole chunk
          // over one bad byte, losing the PIN line with it.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty) onLine(line);
          }, onError: (_) {});
    }
  }

  /// Run the bundled `pair_host.py`, which can advertise a random
  /// identifier — something the pymobiledevice3 CLI cannot express.
  static Future<Process?> _startFreshPairHost({
    required Duration timeout,
  }) async {
    final script = await _pairHostScriptPath();
    if (script == null) return null;
    final python = (await Pymd.tunneldInvocation()).invocation.executable;
    try {
      return await Process.start(
        python,
        [script, advertiseName, '--fresh', '--timeout', '${timeout.inSeconds}'],
        environment: {...Pymd.usbmuxEnvironment(), 'PYTHONUNBUFFERED': '1'},
      );
    } on Object catch (e) {
      Log.logTrace('could not start the fresh pair-host runner: $e');
      return null;
    }
  }

  /// Absolute path to the bundled `pair_host.py`, or null when it cannot be
  /// located (an AOT build resolves it relative to the executable).
  static Future<String?> _pairHostScriptPath() async {
    const relative = 'src/pymd/scripts/pair_host.py';
    final candidates = <String>[
      // Running from source / `dart run`.
      if (await Isolate.resolvePackageUri(
            Uri.parse('package:dart_mobile_device/$relative'),
          )
          case final Uri resolved when resolved.scheme == 'file')
        resolved.toFilePath(),
      // AOT bundle: shipped alongside the executable.
      p.join(p.dirname(Platform.resolvedExecutable), 'scripts', 'pair_host.py'),
      p.join(
        p.dirname(p.dirname(Platform.resolvedExecutable)),
        'scripts',
        'pair_host.py',
      ),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Whether the resolved pymobiledevice3 knows `remote pair-host`
  /// (added upstream for iOS 27 device-initiated pairing).
  static Future<bool> _supportsPairHost() async {
    try {
      await Pymd.run(['remote', 'pair-host', '--help']);
      return true;
    } on Object {
      return false;
    }
  }
}
