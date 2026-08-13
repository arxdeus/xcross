import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:dart_mobile_device/src/errors.dart';

/// GDB-remote packet type.
enum GdbReply {
  /// `O` packet (hex-encoded stdout from the app).
  stdout,

  /// `T` / `S` (signal stop).
  stopped,

  /// `W` (clean exit).
  exited,

  /// `X` (signal kill).
  terminated,

  /// Any other payload.
  other,
}

/// Decoded GDB-remote reply with its raw payload string.
final class GdbReplyPacket {
  const GdbReplyPacket(this.type, this.payload);

  final GdbReply type;
  final String payload;

  /// For [GdbReply.stopped]: the POSIX signal number in a `T`/`S` packet,
  /// e.g. 11 (SIGSEGV) or 6 (SIGABRT). Null when the payload has no
  /// parseable signal byte.
  int? get stopSignal {
    if (type != GdbReply.stopped || payload.length < 3) return null;
    return int.tryParse(payload.substring(1, 3), radix: 16);
  }

  /// Human name for [stopSignal], for the signals a launch actually hits.
  String get stopDescription => switch (stopSignal) {
    4 => 'SIGILL',
    5 => 'SIGTRAP',
    6 => 'SIGABRT (uncaught exception or Kotlin/Native crash)',
    8 => 'SIGFPE',
    10 => 'SIGBUS',
    11 => 'SIGSEGV (bad memory access)',
    final int s => 'signal $s',
    null => 'unknown signal',
  };

  /// Whether this stop is a fatal fault rather than a debugger-expected
  /// pause. SIGTRAP is how the debugger's own breakpoints report, so it must
  /// not be treated as a crash.
  bool get isFatalStop => switch (stopSignal) {
    null || 5 || 0 => false,
    _ => true,
  };

  /// For [GdbReply.stdout]: hex-decoded bytes of the `O` payload.
  Uint8List get stdoutBytes => _hexDecode(payload.substring(1));

  static Uint8List _hexDecode(String hex) {
    final out = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (byte != null) out.add(byte);
    }
    return Uint8List.fromList(out);
  }
}

/// Minimal GDB-remote client over raw TCP: attach, resume, drain stdout
/// (`O` packets), and detect process exit (`W`/`X`).
final class GdbRemoteClient {
  GdbRemoteClient({required this.host, required this.port});

  final String host;
  final int port;

  Socket? _socket;

  final _buffer = <int>[];

  final _replyController = StreamController<GdbReplyPacket>.broadcast();

  Completer<String>? _exchangeCompleter;

  Stream<GdbReplyPacket> get replies => _replyController.stream;

  static const _packetStart = 0x24;
  static const _packetEnd = 0x23;
  static const _checksumWidth = 2;

  Future<void> connect() async {
    final rawHost = ProcessRunner.unbracketHost(host);
    try {
      _socket = await Socket.connect(rawHost, port);
    } catch (e) {
      throw TunnelError('debugproxy connect failed: $e');
    }
    _socket!.listen(
      _onData,
      onError: (_) => _replyController.close(),
      onDone: _replyController.close,
    );
  }

  /// Send the no-ack handshake.
  Future<void> start() async {
    await _sendRaw('+');
    await _exchange('QStartNoAckMode');
    await _exchangeOptional('QThreadSuffixSupported');
    await _exchangeOptional('QListThreadsInStopReply');
  }

  Future<void> _exchangeOptional(String payload) async {
    try {
      await _exchange(payload, timeout: const Duration(seconds: 2));
    } on TunnelError {
      Log.logTrace('debugproxy: $payload not supported, continuing');
    }
  }

  /// `vAttach;<pid hex>`. Returns the raw stop reply (T-packet).
  Future<String> attach(int pid) async {
    final reply = await _exchange('vAttach;${pid.toRadixString(16)}');
    if (!reply.startsWith('T') && !reply.startsWith('S')) {
      throw TunnelError('vAttach rejected: $reply');
    }
    return reply;
  }

  /// Send `c` (continue) without waiting for a reply.
  Future<void> resume() => _sendFramed('c');

  /// Best-effort `k` (kill). Never block forever on a wedged debugproxy flush.
  Future<void> kill() async {
    try {
      await _sendFramed('k').timeout(const Duration(milliseconds: 500));
    } on Object catch (e) {
      Log.logTrace('debugproxy: kill send failed: $e');
    }
  }

  Future<void> close() async {
    final s = _socket;
    _socket = null;
    s?.destroy();
    if (!_replyController.isClosed) await _replyController.close();
  }

  Future<String> _exchange(
    String payload, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final completer = Completer<String>();
    _exchangeCompleter = completer;
    await _sendFramed(payload);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_exchangeCompleter, completer)) _exchangeCompleter = null;
      throw TunnelError('debugproxy: timeout waiting for response to $payload');
    }
  }

  Future<void> _sendFramed(String payload) async {
    final checksum = _checksum(
      payload,
    ).toRadixString(16).padLeft(_checksumWidth, '0');
    await _sendRaw('\$$payload#$checksum');
  }

  Future<void> _sendRaw(String text) async {
    final s = _socket;
    if (s == null) throw TunnelError('debugproxy: not connected');
    s.add(text.codeUnits);
    await s.flush();
  }

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    _drainPackets();
  }

  void _drainPackets() {
    while (true) {
      final start = _buffer.indexOf(_packetStart);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      if (start > 0) _buffer.removeRange(0, start);

      final hash = _buffer.indexOf(_packetEnd);
      if (hash < 0 || _buffer.length < hash + 3) break;

      final payload = String.fromCharCodes(_buffer.sublist(1, hash));
      _buffer.removeRange(0, hash + 3);

      _dispatchPacket(payload);
    }
  }

  void _dispatchPacket(String payload) {
    final c = _exchangeCompleter;
    if (c != null && !c.isCompleted) {
      _exchangeCompleter = null;
      c.complete(payload);
      return;
    }
    if (!_replyController.isClosed) {
      _replyController.add(_classify(payload));
    }
  }

  static GdbReplyPacket _classify(String payload) {
    final first = payload.isEmpty ? '' : payload[0];
    final type = switch (first) {
      'O' => GdbReply.stdout,
      'T' || 'S' => GdbReply.stopped,
      'W' => GdbReply.exited,
      'X' => GdbReply.terminated,
      _ => GdbReply.other,
    };
    return GdbReplyPacket(type, payload);
  }

  static int _checksum(String s) {
    var sum = 0;
    for (final b in s.codeUnits) {
      sum = (sum + b) & 0xff;
    }
    return sum;
  }
}
