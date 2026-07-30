import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/process.dart';

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
class GdbReplyPacket {
  const GdbReplyPacket(this.type, this.payload);

  final GdbReply type;
  final String payload;

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

/// Minimal GDB-remote client over raw TCP, enough to attach, resume, drain
/// stdout (`O` packets), and detect process exit (`W`/`X`).
///
/// Wire format: `$<payload>#<2-hex-checksum>`. After `QStartNoAckMode` we
/// stop expecting `+`/`-` acks from the peer.
class GdbRemoteClient {
  GdbRemoteClient({required this.host, required this.port});

  final String host;
  final int port;

  Socket? _socket;

  final _buffer = <int>[];

  final _replyController = StreamController<GdbReplyPacket>.broadcast();

  /// Single-slot continuation for an in-flight [_exchange]. Safe only because
  /// the app launches suspended and [resume] is the last RPC — any packet that
  /// arrives while this is set resolves the exchange instead of the stream.
  Completer<String>? _exchangeCompleter;

  Stream<GdbReplyPacket> get replies => _replyController.stream;

  /// ASCII `$` — start-of-packet sentinel.
  static const _packetStart = 0x24; // '$'

  /// ASCII `#` — end-of-payload / checksum separator.
  static const _packetEnd = 0x23; // '#'

  /// Checksum field width in ASCII hex digits.
  static const _checksumWidth = 2;

  Future<void> connect() async {
    final rawHost = ProcessRunner.unbracketHost(host);
    try {
      _socket = await Socket.connect(rawHost, port);
    } catch (e) {
      throw XcrossError('debugproxy connect failed: $e');
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
    // Optional optimizations. Some debugproxy implementations (notably
    // pymobiledevice3's on iOS 17+/26) silently ignore these instead of
    // replying with an empty packet. A real debugger treats no-reply as
    // "unsupported" and proceeds — so must we, or the whole attach fails.
    await _exchangeOptional('QThreadSuffixSupported');
    await _exchangeOptional('QListThreadsInStopReply');
  }

  /// Best-effort query: on timeout, assume the peer doesn't support it and
  /// continue (the reply, if any late one arrives, is routed to the stream).
  Future<void> _exchangeOptional(String payload) async {
    try {
      await _exchange(payload, timeout: const Duration(seconds: 2));
    } on XcrossError {
      // Unsupported / ignored by this debugproxy — proceed.
    }
  }

  /// `vAttach;<pid hex>`. Returns the raw stop reply (T-packet).
  Future<String> attach(int pid) async {
    final reply = await _exchange('vAttach;${pid.toRadixString(16)}');
    if (!reply.startsWith('T') && !reply.startsWith('S')) {
      throw XcrossError('vAttach rejected: $reply');
    }
    return reply;
  }

  /// Send `c` (continue) without waiting for a reply.
  Future<void> resume() => _sendFramed('c');

  /// Best-effort `k` (kill).
  Future<void> kill() async {
    try {
      await _sendFramed('k');
    } catch (_) {}
  }

  Future<void> close() async {
    await _socket?.close();
    _socket = null;
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
      // Drop the pending completer so a late reply is classified onto the
      // reply stream instead of hijacking the next _exchange().
      if (identical(_exchangeCompleter, completer)) _exchangeCompleter = null;
      throw XcrossError('debugproxy: timeout waiting for response to $payload');
    }
  }

  /// Frame as `$<payload>#<cc>`. The checksum must stay lowercase and exactly
  /// [_checksumWidth] digits wide or the peer rejects the packet.
  Future<void> _sendFramed(String payload) async {
    final checksum =
        _checksum(payload).toRadixString(16).padLeft(_checksumWidth, '0');
    await _sendRaw('\$$payload#$checksum');
  }

  Future<void> _sendRaw(String text) async {
    final s = _socket;
    if (s == null) throw XcrossError('debugproxy: not connected');
    s.add(text.codeUnits);
    await s.flush();
  }

  void _onData(Uint8List chunk) {
    _buffer.addAll(chunk);
    _drainPackets();
  }

  /// Extract all complete `$payload#cc` packets from [_buffer].
  ///
  /// Each iteration consumes one complete frame. Bytes before `$` are discarded
  /// (spurious acks). The loop breaks when fewer than 3 bytes follow `#` (frame
  /// incomplete) — leaving them buffered for the next [_onData] call.
  /// Scanning for a bare `#` is correct only because GDB RSP hex-encodes `O`
  /// payloads and `}`-escapes `#`/`$`/`}` elsewhere, so an unescaped `#` cannot
  /// appear inside a payload.
  void _drainPackets() {
    while (true) {
      final start = _buffer.indexOf(_packetStart);
      if (start < 0) {
        _buffer.clear();
        break;
      }
      // Discard any leading bytes before `$`.
      if (start > 0) _buffer.removeRange(0, start);

      final hash = _buffer.indexOf(_packetEnd);
      if (hash < 0 || _buffer.length < hash + 3) break; // packet incomplete

      final payload = String.fromCharCodes(_buffer.sublist(1, hash));
      _buffer.removeRange(0, hash + 3); // consume `$payload#xx`

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

  /// GDB-remote checksum: sum of payload code units mod 256.
  static int _checksum(String s) {
    var sum = 0;
    for (final b in s.codeUnits) {
      sum = (sum + b) & 0xff;
    }
    return sum;
  }
}
