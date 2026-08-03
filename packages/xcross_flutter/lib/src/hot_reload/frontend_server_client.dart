import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross_flutter/src/errors.dart';
import 'package:xcross_flutter/src/models/hot_reload_config.dart';
import 'package:xcross_flutter/src/package_uris.dart';

/// Drives a persistent `frontend_server` subprocess over its stdin/stdout
/// protocol, producing incremental kernel diffs for hot reload.
class FrontendServerClient {
  FrontendServerClient(this.config);

  static final _whitespacePattern = RegExp(r'\s+');

  final HotReloadConfig config;

  Process? _process;
  IOSink? _sink;

  /// Loaded once in [spawn]; null when there is no readable package config.
  PackageUris? _packageUris;

  /// Persistent pull-based reader. Returning early from `await for` cancels the
  /// subscription, so the second [_readResultBoundary] would throw StateError
  /// on this single-subscription stream. StreamQueue holds the subscription
  /// internally and allows repeated `hasNext`/`next` across compile rounds.
  StreamQueue<String>? _queue;

  /// Kernel dill the debug build already produced (FlutterDebugBundler). Used to
  /// warm-start the incremental compiler via `--initialize-from-dill`.
  String get _buildKernelDill =>
      '${config.projectRoot}/build/xcross-flutter-debug/.kernel/app.dill';

  Future<void> spawn() async {
    // Must match the URI form the debug build compiled with (see
    // FlutterDebugBundler): this compiler warm-starts from that same dill, so a
    // root library named differently would be treated as a new library rather
    // than an update to the existing one.
    _packageUris = await PackageUris.load(config.packageConfig);

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

    await Directory(
      File(config.outputDill).parent.path,
    ).create(recursive: true);

    Log.logTrace('[frontend_server] running: ${config.dart} ${args.join(' ')}');
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

  /// Serializes everything that talks to the compiler over its stdin/stdout.
  ///
  /// A `compileExpression` from DevTools can arrive at any moment, and
  /// interleaving it with a hot-reload recompile corrupts both the request
  /// framing and the incremental state.
  Future<void> _lock = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    // Swallow the error on the chain only: one failure must not wedge every
    // later request, but the caller still sees it.
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// The entrypoint as a `package:` URI when it has one, else a `file:` URI.
  String get _entrypointUri => _compilerUri(Uri.file(config.entrypoint));

  /// `package:` form of [uri] when available, else [uri] unchanged.
  String _compilerUri(Uri uri) =>
      _packageUris?.toPackageUri(uri)?.toString() ?? uri.toString();

  Future<String> compile() => _serialized(() async {
    await _send('compile $_entrypointUri\n');
    return _readResultBoundary();
  });

  Future<String> recompile({required List<String> invalidated}) =>
      _serialized(() => _recompile(invalidated));

  Future<String> _recompile(List<String> invalidated) async {
    // Hex-encoded microsecond timestamp used as the boundary token that wraps
    // the invalidated-file list in the frontend_server recompile protocol.
    final boundaryToken = DateTime.now().microsecondsSinceEpoch.toRadixString(
      16,
    );
    final sb = StringBuffer()
      ..write('recompile $_entrypointUri $boundaryToken\n');
    for (final uri in invalidated) {
      // Same URI form as the compile above, or the compiler will not match the
      // file and the edit is silently left out of the reload.
      sb.write('${_compilerUri(Uri.parse(uri))}\n');
    }
    sb.write('$boundaryToken\n');
    await _send(sb.toString());
    return _readResultBoundary();
  }

  /// Reset the incremental compiler so the NEXT [recompile] emits a full
  /// kernel component written to `--output-dill` (instead of a delta written to
  /// `<output-dill>.incremental.dill`).
  ///
  /// Required before a hot restart: `_flutter.runInView` needs a complete
  /// program as `mainScript`. Handing it a delta leaves the new isolate unable
  /// to load, so it never becomes runnable and the restart hangs.
  Future<void> reset() => _serialized(() => _send('reset\n'));

  /// Commit the latest output as the next incremental baseline.
  Future<void> accept() => _serialized(() => _send('accept\n'));

  Future<void> reject() => _serialized(() => _send('reject\n'));

  /// Compile [expression] into an expression kernel and return its bytes.
  ///
  /// Serves the VM Service `compileExpression` service. The Flutter engine
  /// embeds no kernel compiler, so the VM delegates expression compilation to a
  /// client; with nobody registered every `evaluate` fails.
  Future<List<int>> compileExpression({
    required String expression,
    required List<String> definitions,
    required List<String> definitionTypes,
    required List<String> typeDefinitions,
    required List<String> typeBounds,
    required List<String> typeDefaults,
    required String libraryUri,
    required String? klass,
    required String? method,
    required bool isStatic,
  }) => _serialized(() async {
    // Line protocol: the header, the expression, then five lists each
    // terminated by the boundary token, then the context. Order and count
    // are fixed — a missing terminator desynchronises the compiler.
    final key = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final sb = StringBuffer()
      ..writeln('compile-expression $key')
      ..writeln(expression);
    for (final list in [
      definitions,
      definitionTypes,
      typeDefinitions,
      typeBounds,
      typeDefaults,
    ]) {
      list.forEach(sb.writeln);
      sb.writeln(key);
    }
    sb
      ..writeln(libraryUri)
      ..writeln(klass ?? '')
      ..writeln(method ?? '')
      ..writeln(isStatic);
    await _send(sb.toString());
    return File(await _readResultBoundary()).readAsBytes();
  });

  Future<void> close() async {
    // ORDER MATTERS: try a polite `quit` first so frontend_server can flush,
    // but never wait forever — a hung stdin flush here is what left `q` stuck
    // with no further CLI I/O on Windows AOT.
    try {
      await _send('quit\n').timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {}
    final process = _process;
    _process = null;
    if (process != null) {
      try {
        await ProcessRunner.killTree(
          process,
        ).timeout(const Duration(seconds: 2));
      } on Object catch (_) {
        process.kill();
      }
    }
    final sink = _sink;
    _sink = null;
    try {
      await sink?.close().timeout(const Duration(milliseconds: 200));
    } on Object catch (_) {}
    await _queue?.cancel(immediate: true);
    _queue = null;
  }

  /// Write [s] to frontend_server stdin and flush. Async so callers can await
  /// delivery — without it accept/reject/quit can be dropped when the process
  /// is killed before the OS buffer is flushed.
  Future<void> _send(String s) async {
    final sink = _sink;
    if (sink == null) {
      throw FlutterBuildError('frontend_server closed unexpectedly');
    }
    sink.write(s);
    await sink.flush();
  }

  /// Parse `result <boundary>\n...\n<boundary> <dill> <errCount>` from stdout.
  /// Returns the local dill file path.
  Future<String> _readResultBoundary() {
    final queue = _queue;
    if (queue == null) {
      throw FlutterBuildError('frontend_server closed unexpectedly');
    }
    // Never block forever: if frontend_server emits no result, fail instead.
    return _parseResultBoundary(queue).timeout(
      const Duration(seconds: 60),
      onTimeout: () =>
          throw FlutterBuildError('frontend_server: no result within 60s'),
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
    throw FlutterBuildError('frontend_server closed unexpectedly');
  }
}
