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

  /// Key/value details in a debugserver T stop reply. S replies have no fields.
  Map<String, String> get stopFields {
    if (type != GdbReply.stopped || payload.length < 4 || payload[0] != 'T') {
      return const {};
    }
    final fields = <String, String>{};
    for (final part in payload.substring(3).split(';')) {
      final separator = part.indexOf(':');
      if (separator > 0) {
        fields[part.substring(0, separator)] = part.substring(separator + 1);
      }
    }
    return fields;
  }

  /// Debugger stop reason, including GDB's standalone watchpoint/breakpoint
  /// fields that do not require a `reason:` field.
  String? get stopReason {
    final fields = stopFields;
    if (fields['reason'] case final String reason) return reason;
    for (final name in const [
      'watch',
      'rwatch',
      'awatch',
      'swbreak',
      'hwbreak',
    ]) {
      if (fields.containsKey(name)) return name;
    }
    return null;
  }

  /// A repeated stop at the same execution point must not be resumed forever.
  String get stopIdentity {
    final fields = stopFields;
    return '${stopSignal ?? 'unknown'}:${fields['thread'] ?? ''}:'
        '${fields['pc'] ?? fields['20'] ?? payload}';
  }

  /// Human name for [stopSignal], for the signals a launch actually hits.
  String get stopDescription => switch (stopSignal) {
    4 => 'SIGILL',
    5 => 'SIGTRAP',
    6 => 'SIGABRT (uncaught exception or Kotlin/Native crash)',
    8 => 'SIGFPE',
    10 => 'SIGBUS',
    11 => 'SIGSEGV (bad memory access)',
    0x91 => 'EXC_BAD_ACCESS (Mach memory fault)',
    0x92 => 'EXC_BAD_INSTRUCTION',
    0x93 => 'EXC_ARITHMETIC',
    0x94 => 'EXC_EMULATION',
    0x95 => 'EXC_SOFTWARE',
    final int s => 'signal $s',
    null => 'unknown signal',
  };

  /// Whether this stop must be reported rather than resumed as an attach pause.
  /// A bare first SIGTRAP may be an attach hand-off; a named stop is not.
  bool get isFatalStop => switch (stopSignal) {
    null => type == GdbReply.stopped,
    5 => stopFields.containsKey('metype') || stopReason != null,
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
    final response = await _exchange('QStartNoAckMode');
    // The response is still sent in acknowledgement mode. debugserver
    // switches modes only after receiving this final acknowledgement.
    await _sendRaw('+');
    if (response != 'OK') {
      throw TunnelError('debugproxy: no-ack mode rejected: $response');
    }
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
