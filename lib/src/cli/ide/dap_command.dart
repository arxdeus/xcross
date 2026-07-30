// STDOUT DISCIPLINE — invariants for everything in this file:
//  1. [DapFraming.encode] via [XcrossDap._send] is the ONLY thing here that
//     touches stdout. A stray byte desynchronises the frame stream for good.
//  2. Never call Log.logStatus() on the DAP code path — it writes to fd1. logWarn /
//     logError go to fd2 and are safe, but an `output` event is better.
//  3. Never start a child with ProcessStartMode.inheritStdio from this process.
//     `xcross flutter run` spawns ~9 grandchildren that write straight to fd1,
//     which is exactly why it runs as a piped child process instead of inline.
//     The tunneld pre-flight must use TunnelDaemon.isReachable() (pure HTTP),
//     never ensureRunning() (reaches Sudo.cacheCredentials -> inheritStdio).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';

/// `xcross dap` — Debug Adapter Protocol server driving `xcross flutter run`.
///
/// Spawned by `.vscode/xcross_dap.dart` (see `xcross vscode`), which VS Code
/// launches through `dart.customFlutterDapPath`.
class DapCommand extends Command<void> {
  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug Adapter Protocol server for the VS Code Run & Debug buttons.';

  @override
  bool get hidden => true;

  @override
  Future<void> run() => XcrossDap().serve();
}

/// `Content-Length` framing for the DAP stdio transport.
///
/// The length is the BYTE count of the UTF-8 payload, never the string length:
/// a single non-ASCII character in a message would otherwise shift every
/// subsequent frame boundary and silently kill the session.
class DapFraming {
  final List<int> _buffer = [];

  static List<int> encode(Object? message) {
    final payload = utf8.encode(jsonEncode(message));
    return [
      ...utf8.encode('Content-Length: ${payload.length}\r\n\r\n'),
      ...payload,
    ];
  }

  /// Append a raw stdin [chunk] and return every message it completes. Chunk
  /// boundaries are arbitrary: one chunk may carry several frames, or half of
  /// one.
  List<Map<String, Object?>> feed(List<int> chunk) {
    _buffer.addAll(chunk);
    final messages = <Map<String, Object?>>[];
    while (true) {
      // latin1 is 1 byte per char, so the char index IS the byte index, and it
      // never throws on arbitrary bytes.
      final headerEnd = latin1.decode(_buffer).indexOf('\r\n\r\n');
      if (headerEnd < 0) break;
      final bodyStart = headerEnd + 4;
      final length =
          _contentLength(latin1.decode(_buffer.sublist(0, headerEnd)));
      if (length == null) {
        // Unparseable header: drop it rather than stall the stream forever.
        _buffer.removeRange(0, bodyStart);
        continue;
      }
      if (_buffer.length - bodyStart < length) break;
      final payload = _buffer.sublist(bodyStart, bodyStart + length);
      _buffer.removeRange(0, bodyStart + length);
      // One bad payload must not discard the frames already decoded from this
      // same chunk; the buffer is advanced, so the stream stays in sync.
      try {
        messages.add(jsonDecode(utf8.decode(payload)) as Map<String, Object?>);
      } on Object catch (e) {
        stderr.writeln('xcross dap: bad payload: $e');
      }
    }
    return messages;
  }

  static int? _contentLength(String header) =>
      int.tryParse(RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
              .firstMatch(header)
              ?.group(1) ??
          '');
}

/// Reassembles a chunked text stream into complete lines.
///
/// Chunk boundaries are arbitrary, so the vm-service marker — and the URI that
/// follows it on the same line — can straddle them. Scanning each chunk in
/// isolation would silently miss it, and the only symptom would be a missing
/// Hot Reload button and no DevTools. Hence its own test.
class LineScanner {
  /// The trailing incomplete line, held until its newline arrives.
  String _partial = '';

  List<String> feed(String text) {
    final lines = (_partial + text).split('\n');
    _partial = lines.removeLast();
    return lines;
  }
}

/// Minimal debug adapter: translates the VS Code toolbar into the `r`/`R`/`q`
/// keypress protocol that [SessionConsole] already speaks over the child's
/// stdin. No breakpoints, no stepping, no variables — the child owns the
/// VM Service.
class XcrossDap {
  final DapFraming _framing = DapFraming();
  final LineScanner _lines = LineScanner();
  bool _vmServiceReported = false;
  int _seq = 0;
  Process? _child;

  /// Requests are handled strictly in arrival order; overlapping handlers would
  /// interleave `r`/`R`/`q` writes.
  Future<void> _pending = Future<void>.value();

  Future<void> serve() async {
    try {
      await for (final chunk in stdin) {
        // A malformed frame must not escape as an unhandled exception and
        // take the whole session down without a trace.
        try {
          for (final message in _framing.feed(chunk)) {
            // catchError terminates the chain's error state: one failed
            // dispatch must not poison every later request.
            _pending = _pending.then((_) => _dispatch(message)).catchError(
                (Object e) =>
                    stderr.writeln('xcross dap: dispatch failed: $e'));
          }
        } on Object catch (e) {
          stderr.writeln('xcross dap: dropped malformed message: $e');
        }
      }
    } on Object catch (_) {
      // stdin errored: same meaning as EOF — the editor is gone.
    }
    // Drain whatever is still queued: EOF can arrive while dispatches are
    // pending, and the process exits as soon as this returns, which would cut
    // their responses off mid-flight.
    await _pending;
    // The editor dropped the pipe: don't leave `xcross flutter run` (and its
    // frontend_server + RSD tunnel) behind.
    _writeKey('q');
    await _reapChild();
  }

  // --- transport -------------------------------------------------------------

  void _send(Map<String, Object?> message) {
    stdout.add(DapFraming.encode({'seq': ++_seq, ...message}));
  }

  void _event(String event, [Map<String, Object?>? body]) =>
      _send({'type': 'event', 'event': event, 'body': body ?? const {}});

  void _respond(Map<String, Object?> request, Object? body) => _send({
        'type': 'response',
        'request_seq': request['seq'],
        'success': true,
        'command': request['command'],
        'body': body,
      });

  void _respondError(Map<String, Object?> request, String message) => _send({
        'type': 'response',
        'request_seq': request['seq'],
        'success': false,
        'command': request['command'],
        'message': message,
      });

  void _output(String category, String text) =>
      _event('output', {'category': category, 'output': text});

  // --- dispatch --------------------------------------------------------------

  Future<void> _dispatch(Map<String, Object?> message) async {
    if (message['type'] != 'request') return;
    final command = message['command'];
    if (command is! String) return;
    // An exception escaping here would desynchronise framing and kill the
    // session with no visible cause, so every path answers something.
    try {
      switch (command) {
        case 'initialize':
          _respond(message, <String, Object?>{
            'supportsRestartRequest': true,
            'supportsTerminateRequest': true,
            'supportsConfigurationDoneRequest': true,
          });
          _event('initialized');
        case 'launch' || 'attach':
          await _start(message);
        case 'configurationDone':
          _respond(message, <String, Object?>{});
        case 'restart' || 'hotRestart':
          _writeKey('R');
          _respond(message, command == 'restart' ? <String, Object?>{} : null);
        case 'hotReload':
          _writeKey('r');
          _respond(message, null);
        case 'threads':
          _respond(message, <String, Object?>{'threads': <Object?>[]});
        case 'setBreakpoints':
          _respond(message, <String, Object?>{
            'breakpoints': _breakpointsOf(message)
                .map((_) => <String, Object?>{'verified': false})
                .toList(),
          });
        case 'setExceptionBreakpoints':
          _respond(message, <String, Object?>{});
        // Sent when the user toggles debug settings or DevTools logging. There
        // is no debugger here to reconfigure, but answering with an error would
        // surface as a spurious failure in the editor.
        case 'updateDebugOptions' || 'updateSendLogsToClient':
          _respond(message, <String, Object?>{});
        case 'disconnect' || 'terminate':
          await _shutdown(message);
        default:
          _respondError(message, 'Unknown command $command');
      }
    } on Object catch (e) {
      _respondError(message, '$command failed: $e');
    }
  }

  static List<Object?> _breakpointsOf(Map<String, Object?> request) {
    if (request['arguments'] case final Map<String, Object?> args) {
      if (args['breakpoints'] case final List<Object?> breakpoints) {
        return breakpoints;
      }
    }
    return const [];
  }

  // --- session ---------------------------------------------------------------

  Future<void> _start(Map<String, Object?> request) async {
    final config = request['arguments'] is Map<String, Object?>
        ? request['arguments']! as Map<String, Object?>
        : const <String, Object?>{};
    final cwd = config['cwd'] is String
        ? config['cwd']! as String
        : Directory.current.path;

    // With tunneld down the child reaches `sudo -v` under inheritStdio and can
    // block forever on a tty nobody can see. Warn, but don't fail: the iOS < 17
    // debugserver path needs no tunneld at all. A half-dead tunneld can accept
    // the socket and never answer, hence the timeout.
    final tunnelUp = await TunnelDaemon.isReachable()
        .timeout(const Duration(seconds: 5), onTimeout: () => false);
    if (!tunnelUp) {
      _output(
          'stderr',
          'xcross: the iOS 17+ RSD tunnel daemon is not reachable.\n'
              'If this is an iOS 17+ device, run `xcross prepare` once in a '
              'terminal (it needs sudo).\n');
    }

    // NEVER forward Dart-Code's `toolArgs`: it injects `-d <deviceId>` and
    // --host-vmservice-port, which makes XtoolCli.resolveDevice throw. Only the
    // user's own `args` from launch.json is passed through.
    final target = switch (config['program']) {
      final String program when p.isAbsolute(program) =>
        p.relative(program, from: cwd),
      final String program => program,
      _ => null,
    };
    final extraArgs = config['args'] is List
        ? (config['args']! as List<Object?>).whereType<String>().toList()
        : const <String>[];

    final child = await Process.start(
      Platform.resolvedExecutable,
      [
        'flutter',
        'run',
        if (target != null) ...['--target', target],
        ...extraArgs,
      ],
      workingDirectory: cwd,
      // Tells SessionConsole that a controller owns its stdin pipe, so EOF
      // there means "editor gone, quit" instead of "no keyboard" (CI, docker
      // without -i). Parent env is still inherited.
      environment: const {'XCROSS_DAP': '1'},
    );
    _child = child;
    // The child may die first; a broken-pipe write reports asynchronously here
    // and would otherwise kill the adapter mid-shutdown.
    child.stdin.done.ignore();
    // Utf8Decoder as a transformer carries a multi-byte sequence across chunk
    // boundaries; utf8.decode() per chunk replaces it with U+FFFD.
    child.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onChildStdout, onError: _childError);
    child.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => _output('stderr', text), onError: _childError);
    // Registered before the response so a child that dies instantly cannot
    // leave a zombie session in the editor.
    unawaited(child.exitCode.then((_) => _event('terminated')));

    _respond(request, <String, Object?>{});
    // Order matters: Dart-Code only wires the Hot Reload button when appStart
    // (with supportsRestart) is followed by appStarted.
    _event('flutter.appStart', <String, Object?>{
      'appId': 'xcross',
      'deviceId': 'ios',
      'mode': 'debug',
      'supportsRestart': true,
    });
  }

  void _childError(Object e) =>
      _output('stderr', 'xcross dap: child stream error: $e\n');

  void _onChildStdout(String text) {
    _output('stdout', text);
    // Stop reassembling lines once the URI is known: nothing else is parsed.
    if (_vmServiceReported) return;
    for (final line in _lines.feed(text)) {
      final start = line.indexOf(DeviceConstants.vmServiceMarker);
      if (start < 0) continue;
      _vmServiceReported = true;
      _event('flutter.appStarted');
      // Hand the raw on-device VM Service URI to the editor so it can point
      // DevTools at it. The reference Flutter adapter does exactly this when it
      // has no debugger of its own connected (flutter_adapter.dart
      // `_connectDebugger`), so no VM Service connection is needed here.
      final uri =
          line.substring(start + DeviceConstants.vmServiceMarker.length).trim();
      if (uri.isNotEmpty) {
        _event('dart.debuggerUris', <String, Object?>{'vmServiceUri': uri});
      }
      return;
    }
  }

  /// `q` first so [SessionConsole] runs its real cleanup (frontend_server,
  /// debugserver, tunneld), then escalate.
  Future<void> _shutdown(Map<String, Object?> request) async {
    _writeKey('q');
    _respond(request, <String, Object?>{});
    await _reapChild();
    await stdout.flush();
    exit(0);
  }

  // ponytail: signals only the direct child. `xcross flutter run` spawns its
  // build-phase grandchildren (clang, pub, xtool) with inheritStdio, so those
  // survive a disconnect mid-build. Needs a process group (no portable
  // setsid on macOS) if that becomes a real problem.
  Future<void> _reapChild() async {
    final child = _child;
    if (child == null) return;
    await child.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
      child.kill();
      return child.exitCode.timeout(const Duration(seconds: 2), onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return -1;
      });
    });
  }

  void _writeKey(String key) {
    try {
      _child?.stdin.add(utf8.encode(key));
    } on Object catch (_) {
      // Child already gone; nothing to steer.
    }
  }
}
