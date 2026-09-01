import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cli_kit/cli_kit.dart';
import 'package:dds/dap.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/dap/dap_router.dart';

/// Stubs the pre-launch DAP handshake, then replays the raw frames into the
/// chosen adapter (xcross or Flutter's own `debug-adapter`) and drops its
/// duplicate responses for already-acked seqs.
final class DapRouter {
  DapRouter(this._input, this._output, this._startXcross);

  static String? _flutterRootOverride;
  static String? _flutterEnvironmentRoot;
  static String? _flutterToolOverride;
  static bool _declarative = false;

  static void configureFlutterResolution({
    required bool declarative,
    String? root,
    String? environmentRoot,
    String? tool,
  }) {
    _flutterRootOverride = root;
    _flutterEnvironmentRoot = environmentRoot;
    _flutterToolOverride = tool;
    _declarative = declarative;
  }

  static void configureFlutterRootOverride(String? root) {
    _flutterRootOverride = root;
  }

  static void resetConfiguration() {
    _flutterRootOverride = null;
    _flutterEnvironmentRoot = null;
    _flutterToolOverride = null;
    _declarative = false;
  }

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
    unawaited(_handoff(launchRequest).then((_) => _finish()).catchError(_fail));
  }

  Future<void> _handoff(Map<String, Object?> launchRequest) async {
    final useXcross = _wantsXcross(launchRequest['arguments']);

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

  /// A session is ours when its launch args carry `env: {XCROSS: true}`
  /// (the legacy top-level `xcross: true` flag still works).
  static bool _wantsXcross(Object? args) {
    if (args is! Map<Object?, Object?>) return false;
    if (args['xcross'] == true) return true;
    if (args['env'] case final Map<Object?, Object?> env) {
      return '${env['XCROSS']}'.toLowerCase() == 'true';
    }
    return false;
  }

  void _startXcrossAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) {
    final channel = ByteStreamServerChannel(inbound, outbound, null);
    _startXcross(channel);
    unawaited(channel.closed.then((_) => _closeRest()));
  }

  Future<bool> _startFlutterAdapter(
    Stream<List<int>> inbound,
    DapResponseFilter outbound,
  ) async {
    var flutterRoot =
        _flutterRootOverride ??
        (_declarative
            ? _flutterEnvironmentRoot
            : Platform.environment['FLUTTER_ROOT']);
    if (flutterRoot == null) {
      final fvm = p.join(Directory.current.path, '.fvm', 'flutter_sdk');
      if (Directory(fvm).existsSync() || Link(fvm).existsSync()) {
        flutterRoot = Link(fvm).resolveSymbolicLinksSync();
      }
    }
    final flutter = flutterRoot == null
        ? _flutterToolOverride
        : p.join(
            flutterRoot,
            'bin',
            Platform.isWindows ? 'flutter.bat' : 'flutter',
          );
    if (flutter == null) {
      stderr.writeln(
        'xcross dap: launch config is missing "env": {"XCROSS": "true"} '
        'and no Flutter SDK is configured — cannot fall back to the Flutter '
        'DAP.\nConfigure roots.flutterSdk, environment FLUTTER_ROOT, or '
        'tools.flutter.',
      );
      await outbound.close();
      return false;
    }
    final child = await ProcessRunner.start(flutter, const ['debug-adapter']);
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
