import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';
import 'package:dart_mobile_device/src/models/device_endpoint.dart';
import 'package:dart_mobile_device/src/pymd/pymd.dart';
import 'package:dart_mobile_device/src/transport/device_transport.dart';

/// RSD over pymobiledevice3's in-process (`--userspace`) tunnel, with every
/// device service republished on loopback.
///
/// The userspace tunnel exists only inside the pymobiledevice3 process that
/// created it, so nothing outside can dial the device address. Each service is
/// therefore fronted by a relay we own: `developer debugserver start-server`
/// for debugproxy and `usbmux forward` for app-owned ports.
///
/// Everything xcross connects to is `127.0.0.1`, and the device itself is
/// reached over usbmux. That is what makes this transport survive conditions
/// where the kernel tunnel cannot be used at all:
///
/// * a VPN kill-switch or firewall that blocks traffic on non-VPN interfaces
///   (the tunnel's IPv6 connect then fails with `WinError 10013`), and
/// * hosts without Administrator/root rights, since no TUN device is created.
class UserspaceTunnelTransport implements DeviceTransport {
  UserspaceTunnelTransport({required this.udid});

  final String udid;

  static const String _loopback = '127.0.0.1';

  /// How long a relay may take to bind. The userspace tunnel performs the full
  /// RemoteXPC handshake over usbmux first, so this is seconds, not instant.
  static const Duration _relayStartTimeout = Duration(seconds: 90);

  final List<Process> _relays = <Process>[];

  final Map<int, DeviceEndpoint> _devicePortRelays = <int, DeviceEndpoint>{};

  DeviceEndpoint? _debugproxy;

  @override
  List<String> get pymdDeviceArgs => ['--userspace', '--udid', udid];

  @override
  String get description => 'userspace tunnel over usbmux (loopback relays)';

  @override
  Future<DeviceEndpoint> debugproxyEndpoint() async =>
      _debugproxy ??= await _startRelay(
        label: 'debugproxy',
        buildArgs: (localPort) => [
          'developer',
          'debugserver',
          'start-server',
          '--local-port',
          '$localPort',
          '--host',
          _loopback,
          ...pymdDeviceArgs,
        ],
      );

  /// Relays [devicePort] over usbmux rather than the tunnel: app sockets are
  /// reachable that way without any RSD handshake, which keeps the hot-reload
  /// path independent of the tunnel entirely.
  @override
  Future<DeviceEndpoint> devicePortEndpoint(int devicePort) async =>
      _devicePortRelays[devicePort] ??= await _startRelay(
        label: 'device port $devicePort',
        buildArgs: (localPort) => [
          'usbmux',
          'forward',
          '$localPort',
          '$devicePort',
          '--host',
          _loopback,
          '--udid',
          udid,
        ],
      );

  @override
  Future<void> close() async {
    final relays = _relays.toList();
    _relays.clear();
    _devicePortRelays.clear();
    _debugproxy = null;
    for (final relay in relays) {
      await ProcessRunner.killTree(relay);
    }
  }

  /// Spawn a long-lived relay and wait until it owns its loopback port.
  Future<DeviceEndpoint> _startRelay({
    required String label,
    required List<String> Function(int localPort) buildArgs,
  }) async {
    final localPort = await _reserveLocalPort();
    final invocation = await Pymd.resolve();
    final arguments = [...invocation.prefixArgs, ...buildArgs(localPort)];

    Log.logTrace(
      '[pymobiledevice3] starting $label relay on $_loopback:$localPort: '
      '${ProcessRunner.commandLine(invocation.executable, arguments)}',
    );

    final Process relay;
    try {
      relay = await Process.start(
        invocation.executable,
        arguments,
        environment: Pymd.usbmuxEnvironment(),
      );
    } on Object catch (e) {
      throw TunnelError('could not start the $label relay: $e');
    }
    _relays.add(relay);

    // Piped, never inheritStdio: an inherited stdin would steal `r`/`R`/`q`
    // from the hot-reload keypress loop for the rest of the session.
    try {
      await relay.stdin.close();
    } on Object catch (_) {}

    final output = StringBuffer();
    _captureOutput(relay, label, output);

    var exited = false;
    unawaited(relay.exitCode.then((_) => exited = true));

    final ready = await ProcessRunner.pollUntil<bool>(
      timeout: _relayStartTimeout,
      interval: const Duration(milliseconds: 300),
      attempt: () async {
        if (exited) return false;
        return await _isPortTaken(localPort) ? true : null;
      },
    );
    if (ready ?? false) {
      Log.logTrace('$label relay ready on $_loopback:$localPort');
      return DeviceEndpoint(host: _loopback, port: localPort);
    }

    await ProcessRunner.killTree(relay);
    _relays.remove(relay);
    final detail = output.toString().trim();
    throw TunnelError(
      exited
          ? 'the $label relay exited before it started listening.'
                '${detail.isEmpty ? '' : '\n$detail'}'
          : 'the $label relay did not start listening within '
                '${_relayStartTimeout.inSeconds}s. Keep the device unlocked '
                'and trusted.${detail.isEmpty ? '' : '\n$detail'}',
    );
  }

  /// Trace every non-empty line the relay prints, keeping a copy in [output]
  /// for the failure message.
  static void _captureOutput(Process relay, String label, StringBuffer output) {
    for (final stream in [relay.stdout, relay.stderr]) {
      stream
          // Lossy on purpose: pymobiledevice3 can emit non-UTF-8 bytes, and a
          // strict decoder would drop the whole chunk.
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isEmpty) return;
            output.writeln(line);
            Log.logTrace('[$label relay] $line');
          }, onError: (Object _) {});
    }
  }

  /// Ask the OS for a free loopback port, then hand it to the relay.
  ///
  /// Racy in principle; in practice the relay claims it within milliseconds and
  /// [_isPortTaken] confirms the claim.
  static Future<int> _reserveLocalPort() async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    return port;
  }

  /// Whether something already listens on [port].
  ///
  /// Probing by *binding* rather than connecting matters: a connect would open
  /// a real debugserver session and could consume the relay's connection slot
  /// before the debugger gets there.
  static Future<bool> _isPortTaken(int port) async {
    try {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await probe.close();
      return false;
    } on SocketException {
      return true;
    }
  }
}
