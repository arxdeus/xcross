import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dds/dap.dart';
import 'package:meta/meta.dart';
import 'package:xcross_dap/src/internal/dap_router.dart';

/// One parsed DAP frame: the exact bytes as received, plus its decoded body.
@immutable
final class DapMessage {
  const DapMessage({required this.raw, required this.json});

  final Uint8List raw;
  final Map<String, Object?> json;
}

/// Gates the DAP session until `launch`/`attach`, then either runs
/// [startXcross] (when launch.json has `"xcross": true`) or proxies to
/// Flutter's own `debug-adapter`.
abstract final class DapSession {
  static Future<void> run({
    required void Function(ByteStreamServerChannel channel) startXcross,
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
  }) {
    return DapRouter(input ?? stdin, output ?? stdout, startXcross).run();
  }
}

/// Encodes one DAP message with Content-Length framing.
abstract final class DapFrame {
  static Uint8List encode(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
    final out = Uint8List(header.length + body.length);
    out.setAll(0, header);
    out.setAll(header.length, body);
    return out;
  }
}

/// Incremental DAP frame parser. [push] yields complete frames; [takeBuffered]
/// returns any trailing unparsed bytes (for handoff to a child process).
final class DapFrameParser {
  static const _cr = 13;
  static const _lf = 10;
  static const _terminatorLength = 4;

  var _buffer = Uint8List(0);
  var _headerEnd = -1;
  var _contentLength = -1;

  List<DapMessage> push(List<int> chunk) {
    _buffer = _concat(_buffer, chunk);
    final out = <DapMessage>[];
    while (true) {
      if (_headerEnd < 0) {
        _headerEnd = _indexOfHeaderEnd(_buffer);
        if (_headerEnd < 0) break;
        _contentLength = _parseContentLength(_buffer, _headerEnd);
      }
      final bodyStart = _headerEnd + _terminatorLength;
      if (_buffer.length < bodyStart + _contentLength) break;

      final raw = _buffer.sublist(0, bodyStart + _contentLength);
      final json =
          jsonDecode(utf8.decode(raw.sublist(bodyStart)))
              as Map<String, Object?>;
      out.add(DapMessage(raw: raw, json: json));

      _buffer = _buffer.sublist(raw.length);
      _headerEnd = -1;
      _contentLength = -1;
    }
    return out;
  }

  Uint8List takeBuffered() {
    final bytes = _buffer;
    _buffer = Uint8List(0);
    _headerEnd = -1;
    _contentLength = -1;
    return bytes;
  }

  static Uint8List _concat(Uint8List head, List<int> tail) {
    final out = Uint8List(head.length + tail.length);
    out.setRange(0, head.length, head);
    out.setRange(head.length, out.length, tail);
    return out;
  }

  static int _indexOfHeaderEnd(Uint8List bytes) {
    for (var i = 0; i + _terminatorLength <= bytes.length; i++) {
      if (bytes[i] == _cr &&
          bytes[i + 1] == _lf &&
          bytes[i + 2] == _cr &&
          bytes[i + 3] == _lf) {
        return i;
      }
    }
    return -1;
  }

  static int _parseContentLength(Uint8List bytes, int headerEnd) {
    final headers = ascii.decode(bytes.sublist(0, headerEnd));
    for (final line in headers.split('\r\n')) {
      if (line.toLowerCase().startsWith('content-length:')) {
        return int.parse(line.substring(line.indexOf(':') + 1).trim());
      }
    }
    throw const FormatException('DAP frame missing Content-Length');
  }
}

/// Forwards adapter→client DAP frames, dropping responses for [answered]
/// request seqs and a duplicate `initialized` event from the real adapter.
final class DapResponseFilter implements StreamSink<List<int>> {
  DapResponseFilter(this._out, this._answered);

  final StreamSink<List<int>> _out;
  final Set<int> _answered;
  final _parser = DapFrameParser();
  var _dropInitialized = true;
  final _done = Completer<void>();

  @override
  void add(List<int> data) {
    for (final frame in _parser.push(data)) {
      if (_shouldForward(frame.json)) {
        _out.add(frame.raw);
      }
    }
  }

  bool _shouldForward(Map<String, Object?> msg) {
    switch (msg['type']) {
      case 'response':
        final reqSeq = msg['request_seq'];
        return reqSeq is! int || !_answered.contains(reqSeq);
      case 'event':
        if (_dropInitialized && msg['event'] == 'initialized') {
          _dropInitialized = false;
          return false;
        }
        return true;
      default:
        return true;
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _out.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    final rest = _parser.takeBuffered();
    if (rest.isNotEmpty) _out.add(rest);
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
