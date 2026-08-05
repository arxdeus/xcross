import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:frontend_server_kit/src/errors.dart';
import 'package:frontend_server_kit/src/frontend_server_options.dart';
import 'package:frontend_server_kit/src/package_uris.dart';
import 'package:frontend_server_kit/src/process_kill.dart';

/// Drives a persistent `frontend_server` subprocess over its stdin/stdout
/// protocol, producing incremental kernel diffs for hot reload.
class FrontendServerSession {
  FrontendServerSession(this.options);

  static final _whitespacePattern = RegExp(r'\s+');

  final FrontendServerOptions options;

  Process? _process;
  IOSink? _sink;

  /// Loaded once in [spawn]; null when there is no readable package config.
  PackageUris? _packageUris;

  /// Persistent pull-based reader. Returning early from `await for` cancels the
  /// subscription, so the second [parseResultBoundary] would throw StateError
  /// on this single-subscription stream. StreamQueue holds the subscription
  /// internally and allows repeated `hasNext`/`next` across compile rounds.
  StreamQueue<String>? _queue;

  Future<void> spawn() async {
    // Must match the URI form the initial kernel compile used: this compiler
    // warm-starts from that same dill when [initializeFromDill] is set, so a
    // root library named differently would be treated as a new library rather
    // than an update to the existing one.
    _packageUris = await PackageUris.load(options.packageConfig);

    final args = _spawnArguments();
    await Directory(
      File(options.outputDill).parent.path,
    ).create(recursive: true);

    options.onTrace?.call(
      '[frontend_server] running: ${options.dart} ${args.join(' ')}',
    );
    final proc = await Process.start(options.dart, args);

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

  List<String> _spawnArguments() {
    // An `_aot` snapshot runs under `dartaotruntime`, which does not accept
    // the `dart`-only `--disable-dart-dev` flag.
    final isAot = options.frontendServer.contains('_aot');
    final sdkRoot = options.sdkRoot.endsWith('/')
        ? options.sdkRoot
        : '${options.sdkRoot}/';
    return [
      if (!isAot) '--disable-dart-dev',
      options.frontendServer,
      '--sdk-root', sdkRoot,
      '--incremental',
      '--target=${options.target}',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      if (options.trackWidgetCreation) '--track-widget-creation',
      for (final define in options.dartDefines) '-D$define',
      // Warm-start the incremental compiler from a prior full kernel so the
      // initial compile is a fast delta instead of a cold full compile.
      if (options.initializeFromDill case final dill?) ...[
        '--initialize-from-dill',
        dill,
      ],
      '--packages', options.packageConfig,
      '--output-dill', options.outputDill,
    ];
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
  String get _entrypointUri => _compilerUri(Uri.file(options.entrypoint));

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
  /// host; with nobody registered every `evaluate` fails.
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
    final key = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    await _send(
      FrontendServerSession.buildCompileExpressionCommand(
        boundaryKey: key,
        expression: expression,
        definitions: definitions,
        definitionTypes: definitionTypes,
        typeDefinitions: typeDefinitions,
        typeBounds: typeBounds,
        typeDefaults: typeDefaults,
        libraryUri: libraryUri,
        klass: klass,
        method: method,
        isStatic: isStatic,
      ),
    );
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
        await ProcessKill.killTree(process).timeout(const Duration(seconds: 2));
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
      throw FrontendServerException('frontend_server closed unexpectedly');
    }
    sink.write(s);
    await sink.flush();
  }

  /// Parse `result <boundary>\n...\n<boundary> <dill> <errCount>` from stdout.
  /// Returns the local dill file path.
  Future<String> _readResultBoundary() {
    final queue = _queue;
    if (queue == null) {
      throw FrontendServerException('frontend_server closed unexpectedly');
    }
    // Never block forever: if frontend_server emits no result, fail instead.
    return parseResultBoundary(queue).timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw FrontendServerException(
        'frontend_server: no result within 60s',
      ),
    );
  }

  /// Parse `result <boundary>\n...\n<boundary> <dill> <errCount>` from [queue].
  ///
  /// Exposed for tests of the line protocol framing.
  static Future<String> parseResultBoundary(StreamQueue<String> queue) async {
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
    throw FrontendServerException('frontend_server closed unexpectedly');
  }

  /// Builds the stdin payload for `compile-expression`.
  ///
  /// Line protocol: the header, the expression, then five lists each terminated
  /// by the boundary token, then the context. Order and count are fixed — a
  /// missing terminator desynchronises the compiler.
  static String buildCompileExpressionCommand({
    required String boundaryKey,
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
  }) {
    final sb = StringBuffer()
      ..writeln('compile-expression $boundaryKey')
      ..writeln(expression);
    for (final list in [
      definitions,
      definitionTypes,
      typeDefinitions,
      typeBounds,
      typeDefaults,
    ]) {
      list.forEach(sb.writeln);
      sb.writeln(boundaryKey);
    }
    sb
      ..writeln(libraryUri)
      ..writeln(klass ?? '')
      ..writeln(method ?? '')
      ..writeln(isStatic);
    return sb.toString();
  }
}
