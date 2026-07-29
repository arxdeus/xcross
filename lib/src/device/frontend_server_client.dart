import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Drives a persistent `frontend_server` subprocess over its stdin/stdout
/// protocol, producing incremental kernel diffs for hot reload.
class FrontendServerClient {
  FrontendServerClient(this.config);

  static final _whitespacePattern = RegExp(r'\s+');

  final HotReloadConfig config;

  Process? _process;
  IOSink? _sink;

  /// Persistent pull-based reader. Returning early from `await for` cancels the
  /// subscription, so the second [_readResultBoundary] would throw StateError
  /// on this single-subscription stream. StreamQueue holds the subscription
  /// internally and allows repeated `hasNext`/`next` across compile rounds.
  StreamQueue<String>? _queue;

  /// Kernel dill the debug build already produced (FlutterDebugBundler). Used to
  /// warm-start the incremental compiler via `--initialize-from-dill`.
  String get _buildKernelDill =>
      '${config.projectRoot}/build/xtool-flutter-debug/.kernel/app.dill';

  Future<void> spawn() async {
    final isAot = config.frontendServer.contains('_aot');
    final args = <String>[
      if (!isAot) '--disable-dart-dev',
      config.frontendServer,
      '--sdk-root',
      if (config.sdkRoot.endsWith('/'))
        config.sdkRoot
      else
        '${config.sdkRoot}/',
      '--incremental',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--track-widget-creation',
      for (final d in config.dartDefines) '-D$d',
      // Warm-start the incremental compiler from the kernel the build already
      // produced, so the initial compile is a fast delta instead of a cold full
      // compile — cuts the wait before "hot reload ready".
      if (File(_buildKernelDill).existsSync()) ...[
        '--initialize-from-dill',
        _buildKernelDill,
      ],
      '--packages',
      config.packageConfig,
      '--output-dill',
      config.outputDill,
    ];

    await Directory(File(config.outputDill).parent.path)
        .create(recursive: true);

    logStatus('[frontend_server] running: ${config.dart} ${args.join(' ')}');
    final proc = await Process.start(config.dart, args);

    _process = proc;
    _sink = proc.stdin;
    _queue = StreamQueue<String>(
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    // Forward compile errors to our stderr with a program prefix.
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[frontend_server] $line'));
  }

  Future<String> compile() async {
    final entrypointUri = Uri.file(config.entrypoint).toString();
    await _send('compile $entrypointUri\n');
    return _readResultBoundary();
  }

  Future<String> recompile({required List<String> invalidated}) async {
    final entrypointUri = Uri.file(config.entrypoint).toString();
    // Hex-encoded microsecond timestamp used as the boundary token that wraps
    // the invalidated-file list in the frontend_server recompile protocol.
    final boundaryToken =
        DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final sb = StringBuffer()
      ..write('recompile $entrypointUri $boundaryToken\n');
    for (final uri in invalidated) {
      sb.write('$uri\n');
    }
    sb.write('$boundaryToken\n');
    await _send(sb.toString());
    return _readResultBoundary();
  }

  /// Commit the latest output as the next incremental baseline.
  Future<void> accept() => _send('accept\n');

  Future<void> reject() => _send('reject\n');

  Future<void> close() async {
    // ORDER MATTERS: `quit` must be flushed before kill() or the write is
    // dropped and frontend_server is orphaned — one leaked compiler per run.
    await _send('quit\n');
    _process?.kill();
    _process = null;
    await _sink?.close();
    _sink = null;
    await _queue?.cancel(immediate: true);
    _queue = null;
  }

  /// Write [s] to frontend_server stdin and flush. Async so callers can await
  /// delivery — without it accept/reject/quit can be dropped when the process
  /// is killed before the OS buffer is flushed.
  Future<void> _send(String s) async {
    final sink = _sink;
    if (sink == null) throw XcrossError('frontend_server closed unexpectedly');
    sink.write(s);
    await sink.flush();
  }

  /// Parse `result <boundary>\n...\n<boundary> <dill> <errCount>` from stdout.
  /// Returns the local dill file path.
  Future<String> _readResultBoundary() {
    final queue = _queue;
    if (queue == null) throw XcrossError('frontend_server closed unexpectedly');
    // Never block forever: if frontend_server emits no result, fail instead.
    return _parseResultBoundary(queue).timeout(
      const Duration(seconds: 60),
      onTimeout: () =>
          throw XcrossError('frontend_server: no result within 60s'),
    );
  }

  static Future<String> _parseResultBoundary(StreamQueue<String> queue) async {
    String? boundary;
    while (await queue.hasNext) {
      final line = await queue.next;
      if (boundary == null) {
        if (line.startsWith('result ')) {
          boundary = line.substring('result '.length).trim();
        }
        continue;
      }
      if (line.startsWith(boundary)) {
        // frontend_server prints the boundary token alone first, then again as
        // "<boundary> <dill> <errcount>". Skip the bare echo and keep reading
        // until the line that carries the dill path.
        final rest = line.substring(boundary.length).trim();
        if (rest.isEmpty) continue;
        final parts = rest.split(_whitespacePattern);
        // Trailing token is the error count; everything before it is the path.
        final dill = switch (parts) {
          [...final pathTokens, _] when pathTokens.isNotEmpty =>
            pathTokens.join(' '),
          _ => rest,
        };
        if (dill.isEmpty) continue;
        return dill;
      }
    }
    throw XcrossError('frontend_server closed unexpectedly');
  }
}
