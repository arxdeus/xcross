import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dds/dap.dart';
import 'package:path/path.dart' as p;

/// One parsed DAP frame: the exact bytes as received, plus its decoded body.
typedef DapMessage = ({Uint8List raw, Map<String, Object?> json});

/// Gates the DAP session until `launch`/`attach`, then either runs [startXcross]
/// (when launch.json has `"xcross": true`) or proxies to Flutter's own
/// `debug-adapter`.
///
/// Dart-Code only reads `dart.customFlutterDapPath` from settings — every
/// Flutter session in the workspace hits this process. Mid-session handoff is
/// impossible (initialize must be answered before launch arrives), so we stub
/// the pre-launch handshake ourselves, then replay the raw frames into the
/// chosen adapter and drop its duplicate responses for already-acked seqs.
abstract final class DapSession {
  static Future<void> run({
    required void Function(ByteStreamServerChannel channel) startXcross,
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
  }) {
    return _DapRouter(input ?? stdin, output ?? stdout, startXcross).run();
  }
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

  /// Claimed before we know which adapter will serve the session, so this is
  /// the set both the xcross and Flutter adapters honour.
  static const _initializeCapabilities = <String, Object?>{
    'supportsConfigurationDoneRequest': true,
    'supportsRestartRequest': true,
    'supportsTerminateRequest': true,
    'supportsConditionalBreakpoints': true,
    'supportsDelayedStackTraceLoading': true,
    'supportsEvaluateForHovers': true,
    'supportsLogPoints': true,
    'exceptionBreakpointFilters': [
      {'filter': 'All', 'label': 'All Exceptions', 'default': false},
      {'filter': 'Unhandled', 'label': 'Uncaught Exceptions', 'default': true},
    ],
  };

  Future<void> run() {
    _input.listen(
      _onChunk,
      onError: _fail,
      onDone: () {
        _closeRest();
        if (!_forwarding) _finish();
      },
    );
    return _done.future;
  }

  void _finish() {
    if (!_done.isCompleted) _done.complete();
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (!_done.isCompleted) _done.completeError(error, stackTrace);
  }

  void _closeRest() {
    if (!_rest.isClosed) unawaited(_rest.close());
  }

  void _onChunk(List<int> chunk) {
    if (_forwarding) {
      _rest.add(chunk);
      return;
    }
    for (final frame in _parser.push(chunk)) {
      _replay.add(frame.raw);
      if (_handleRequest(frame.json)) return;
    }
  }

  /// Answers one pre-launch request. Returns true once this router should
  /// stop parsing frames itself — handoff started, or the session ended.
  bool _handleRequest(Map<String, Object?> msg) {
    if (msg['type'] != 'request') return false;
    final command = msg['command'] as String?;
    final seq = msg['seq'] as int?;
    if (command == null || seq == null) return false;

    switch (command) {
      case 'launch' || 'attach':
        _beginHandoff(msg);
        return true;
      case 'disconnect' || 'terminate':
        _answered.add(seq);
        _sendResponse(command, seq);
        _finish();
        return true;
      default:
        _answered.add(seq);
        _ack(command, seq, msg);
        return false;
    }
  }

  void _beginHandoff(Map<String, Object?> launchRequest) {
    _forwarding = true;
    final buffered = _parser.takeBuffered();
    if (buffered.isNotEmpty) _rest.add(buffered);
    // stdin onDone closes _rest later; keep it open for live bytes.
    unawaited(_handoff(launchRequest).then((_) => _finish()).catchError(_fail));
  }

  Future<void> _handoff(Map<String, Object?> launchRequest) async {
    final args = launchRequest['arguments'];
    final useXcross = args is Map<Object?, Object?> && args['xcross'] == true;

    final filtered = DapResponseFilter(_output, _answered);
    final inbound = StreamController<List<int>>();

    if (useXcross) {
      _startXcrossAdapter(inbound.stream, filtered);
    } else if (!await _startFlutterAdapter(inbound.stream, filtered)) {
      return;
    }

    for (final frame in _replay) {
      inbound.add(frame);
    }
    await _rest.stream.pipe(inbound);
  }

  void _startXcrossAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) {
    final channel = ByteStreamServerChannel(inbound, outbound, null);
    _startXcross(channel);
    unawaited(channel.closed.then((_) => _closeRest()));
  }

  /// Spawns `flutter debug-adapter` and wires it to [inbound]/[outbound].
  /// Returns false when it could not start — the reason is already reported.
  Future<bool> _startFlutterAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) async {
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot == null) {
      stderr.writeln(
        'xcross dap: launch.json is missing "xcross": true and '
        'FLUTTER_ROOT is unset — cannot fall back to the Flutter DAP.\n'
        'Add "xcross": true to this config, or fix FLUTTER_ROOT.',
      );
      await outbound.close();
      return false;
    }
    final flutter = p.join(
      flutterRoot,
      'bin',
      Platform.isWindows ? 'flutter.bat' : 'flutter',
    );
    final child = await Process.start(flutter, const ['debug-adapter']);
    child.stderr.listen(stderr.add, onError: (_) {});
    inbound.listen(
      child.stdin.add,
      onError: (_) {},
      onDone: child.stdin.close,
      cancelOnError: false,
    );
    child.stdout.listen(outbound.add, onError: (_) {}, onDone: outbound.close);
    unawaited(child.exitCode.then((_) => _closeRest()));
    return true;
  }

  void _ack(String command, int requestSeq, Map<String, Object?> request) {
    switch (command) {
      case 'initialize':
        _sendResponse(command, requestSeq, body: _initializeCapabilities);
        _sendEvent('initialized', const <String, Object?>{});
      case 'setBreakpoints':
        _sendResponse(
          command,
          requestSeq,
          body: {'breakpoints': _unverifiedBreakpoints(request)},
        );
      default:
        _sendResponse(command, requestSeq);
    }
  }

  /// Echoes the requested lines back as unverified: the real adapter will
  /// re-resolve them once the replayed `setBreakpoints` reaches it.
  static List<Map<String, Object?>> _unverifiedBreakpoints(
    Map<String, Object?> request,
  ) {
    final args = request['arguments'];
    final breakpoints = args is Map<Object?, Object?>
        ? args['breakpoints']
        : null;
    if (breakpoints is! List) return const [];
    return breakpoints
        .whereType<Map<Object?, Object?>>()
        .map((b) => {'verified': false, 'line': b['line']})
        .toList();
  }

  void _sendResponse(String command, int requestSeq, {Object? body}) {
    _output.add(
      DapFrame.encode({
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
      DapFrame.encode({
        'seq': _outSeq++,
        'type': 'event',
        'event': event,
        if (body != null) 'body': body,
      }),
    );
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
class DapFrameParser {
  /// `\r\n\r\n` separates a DAP frame's headers from its body.
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
      out.add((raw: raw, json: json));

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
