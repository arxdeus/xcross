import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dds/dap.dart';
import 'package:path/path.dart' as p;

/// Gates the DAP session until `launch`/`attach`, then either runs [startXcross]
/// (when launch.json has `"xcross": true`) or proxies to Flutter's own
/// `debug-adapter`.
///
/// Dart-Code only reads `dart.customFlutterDapPath` from settings — every
/// Flutter session in the workspace hits this process. Mid-session handoff is
/// impossible (initialize must be answered before launch arrives), so we stub
/// the pre-launch handshake ourselves, then replay the raw frames into the
/// chosen adapter and drop its duplicate responses for already-acked seqs.
Future<void> runDapSession({
  required void Function(ByteStreamServerChannel channel) startXcross,
  Stream<List<int>>? input,
  StreamSink<List<int>>? output,
}) {
  return _DapRouter(input ?? stdin, output ?? stdout, startXcross).run();
}

class _DapRouter {
  _DapRouter(this._input, this._output, this._startXcross);

  final Stream<List<int>> _input;
  final StreamSink<List<int>> _output;
  final void Function(ByteStreamServerChannel channel) _startXcross;

  final _parser = DapFrameParser();
  final _replay = <Uint8List>[];
  final _answered = <int>{};
  var _outSeq = 1;
  var _forwarding = false;
  final _rest = StreamController<List<int>>();
  final _done = Completer<void>();

  Future<void> run() {
    _input.listen(
      _onChunk,
      onError: (Object e, StackTrace st) {
        if (!_done.isCompleted) _done.completeError(e, st);
      },
      onDone: () {
        if (!_rest.isClosed) _rest.close();
        if (!_forwarding && !_done.isCompleted) _done.complete();
      },
    );
    return _done.future;
  }

  void _onChunk(List<int> chunk) {
    if (_forwarding) {
      _rest.add(chunk);
      return;
    }
    for (final frame in _parser.push(chunk)) {
      _replay.add(frame.raw);
      final msg = frame.json;
      if (msg['type'] != 'request') continue;

      final command = msg['command'] as String?;
      final seq = msg['seq'] as int?;
      if (command == null || seq == null) continue;

      if (command == 'launch' || command == 'attach') {
        _forwarding = true;
        final buffered = _parser.takeBuffered();
        if (buffered.isNotEmpty) _rest.add(buffered);
        // stdin onDone closes _rest later; keep it open for live bytes.
        unawaited(
          _handoff(msg)
              .then((_) {
                if (!_done.isCompleted) _done.complete();
              })
              .catchError((Object e, StackTrace st) {
                if (!_done.isCompleted) _done.completeError(e, st);
              }),
        );
        return;
      }

      if (command == 'disconnect' || command == 'terminate') {
        _answered.add(seq);
        _sendResponse(command, seq);
        if (!_done.isCompleted) _done.complete();
        return;
      }

      _answered.add(seq);
      _ack(command, seq, msg);
    }
  }

  Future<void> _handoff(Map<String, Object?> launchRequest) async {
    final args = launchRequest['arguments'];
    final xcross = args is Map<Object?, Object?> && args['xcross'] == true;

    final filtered = DapResponseFilter(_output, _answered);
    final inbound = StreamController<List<int>>();

    if (xcross) {
      final channel = ByteStreamServerChannel(inbound.stream, filtered, null);
      _startXcross(channel);
      unawaited(
        channel.closed.then((_) {
          if (!_rest.isClosed) _rest.close();
        }),
      );
    } else {
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      if (flutterRoot == null) {
        stderr.writeln(
          'xcross dap: launch.json is missing "xcross": true and '
          'FLUTTER_ROOT is unset — cannot fall back to the Flutter DAP.\n'
          'Add "xcross": true to this config, or fix FLUTTER_ROOT.',
        );
        await filtered.close();
        return;
      }
      final flutter = p.join(
        flutterRoot,
        'bin',
        Platform.isWindows ? 'flutter.bat' : 'flutter',
      );
      final child = await Process.start(flutter, const ['debug-adapter']);
      child.stderr.listen(stderr.add, onError: (_) {});
      inbound.stream.listen(
        child.stdin.add,
        onError: (_) {},
        onDone: child.stdin.close,
        cancelOnError: false,
      );
      child.stdout.listen(
        filtered.add,
        onError: (_) {},
        onDone: filtered.close,
      );
      unawaited(
        child.exitCode.then((_) {
          if (!_rest.isClosed) _rest.close();
        }),
      );
    }

    for (final frame in _replay) {
      inbound.add(frame);
    }
    await _rest.stream.pipe(inbound);
  }

  void _ack(String command, int requestSeq, Map<String, Object?> request) {
    Object? body;
    if (command == 'initialize') {
      body = {
        'supportsConfigurationDoneRequest': true,
        'supportsRestartRequest': true,
        'supportsTerminateRequest': true,
        'supportsConditionalBreakpoints': true,
        'supportsDelayedStackTraceLoading': true,
        'supportsEvaluateForHovers': true,
        'supportsLogPoints': true,
        'exceptionBreakpointFilters': [
          {'filter': 'All', 'label': 'All Exceptions', 'default': false},
          {
            'filter': 'Unhandled',
            'label': 'Uncaught Exceptions',
            'default': true,
          },
        ],
      };
      _sendResponse(command, requestSeq, body: body);
      _sendEvent('initialized', const <String, Object?>{});
      return;
    }
    if (command == 'setBreakpoints') {
      final args = request['arguments'];
      final bps = args is Map<Object?, Object?> ? args['breakpoints'] : null;
      final lines = bps is List
          ? bps
                .whereType<Map<Object?, Object?>>()
                .map((b) => {'verified': false, 'line': b['line']})
                .toList()
          : const <Map<String, Object?>>[];
      body = {'breakpoints': lines};
    }
    _sendResponse(command, requestSeq, body: body);
  }

  void _sendResponse(String command, int requestSeq, {Object? body}) {
    _output.add(
      encodeDapFrame({
        'seq': _outSeq++,
        'type': 'response',
        'request_seq': requestSeq,
        'success': true,
        'command': command,
        if (body != null) 'body': body,
      }),
    );
  }

  void _sendEvent(String event, Object? body) {
    _output.add(
      encodeDapFrame({
        'seq': _outSeq++,
        'type': 'event',
        'event': event,
        if (body != null) 'body': body,
      }),
    );
  }
}

/// Encodes one DAP message with Content-Length framing.
Uint8List encodeDapFrame(Map<String, Object?> message) {
  final body = utf8.encode(jsonEncode(message));
  final header = ascii.encode('Content-Length: ${body.length}\r\n\r\n');
  final out = Uint8List(header.length + body.length);
  out.setAll(0, header);
  out.setAll(header.length, body);
  return out;
}

/// Incremental DAP frame parser. [push] yields complete frames; [takeBuffered]
/// returns any trailing unparsed bytes (for handoff to a child process).
class DapFrameParser {
  final _buffer = BytesBuilder(copy: false);
  var _headerEnd = -1;
  var _contentLength = -1;

  List<({Uint8List raw, Map<String, Object?> json})> push(List<int> chunk) {
    _buffer.add(chunk);
    final out = <({Uint8List raw, Map<String, Object?> json})>[];
    while (true) {
      final bytes = _buffer.toBytes();
      if (_headerEnd < 0) {
        _headerEnd = _indexOfHeaderEnd(bytes);
        if (_headerEnd < 0) {
          _buffer.clear();
          _buffer.add(bytes);
          break;
        }
        _contentLength = _parseContentLength(bytes, _headerEnd);
      }
      final frameLen = _headerEnd + 4 + _contentLength;
      if (bytes.length < frameLen) {
        _buffer.clear();
        _buffer.add(bytes);
        break;
      }
      final raw = Uint8List.fromList(bytes.sublist(0, frameLen));
      final body = utf8.decode(raw.sublist(_headerEnd + 4));
      final json = jsonDecode(body) as Map<String, Object?>;
      out.add((raw: raw, json: json));
      final rest = bytes.sublist(frameLen);
      _buffer.clear();
      _buffer.add(rest);
      _headerEnd = -1;
      _contentLength = -1;
    }
    return out;
  }

  Uint8List takeBuffered() {
    final bytes = Uint8List.fromList(_buffer.takeBytes());
    _headerEnd = -1;
    _contentLength = -1;
    return bytes;
  }

  static int _indexOfHeaderEnd(List<int> bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static int _parseContentLength(List<int> bytes, int headerEnd) {
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
class DapResponseFilter implements StreamSink<List<int>> {
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
    // Don't close stdout — the process owns it.
  }

  @override
  Future<void> get done => _done.future;
}
