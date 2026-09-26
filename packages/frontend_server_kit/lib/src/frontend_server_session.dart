import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:frontend_server_kit/src/errors.dart';
import 'package:frontend_server_kit/src/frontend_server_options.dart';
import 'package:frontend_server_kit/src/internal/process_kill.dart';
import 'package:frontend_server_kit/src/package_uris.dart';

/// Drives a persistent `frontend_server` subprocess over its stdin/stdout
/// protocol, producing incremental kernel diffs for hot reload.
final class FrontendServerSession {
  FrontendServerSession(this.options);

  static final _whitespacePattern = RegExp(r'\s+');

  final FrontendServerOptions options;

  Process? _process;
  IOSink? _sink;

  PackageUris? _packageUris;

  // StreamQueue holds the subscription so repeated hasNext/next works across
  // compile rounds; a plain `await for` would cancel it on early return.
  StreamQueue<String>? _queue;

  Future<void> spawn() async {
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
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[frontend_server] $line'));
  }

  List<String> _spawnArguments() {
    // `_aot` snapshots run under dartaotruntime, which rejects the
    // dart-only `--disable-dart-dev` flag.
    final isAot = options.frontendServer.contains('_aot');
    final sdkRoot = options.sdkRoot.endsWith('/')
        ? options.sdkRoot
        : '${options.sdkRoot}/';
    return [
      if (!isAot) '--disable-dart-dev',
      options.frontendServer,
      '--sdk-root',
      sdkRoot,
      '--incremental',
      '--no-link-platform',
      '--target=${options.target}',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      if (options.trackWidgetCreation) '--track-widget-creation',
      for (final define in options.dartDefines) '-D$define',
      if (options.initializeFromDill case final dill?) ...[
        '--initialize-from-dill',
        dill,
      ],
      for (final source in options.additionalSources) ...[
        '--source',
        source.toString(),
      ],
      '--packages',
      options.packageConfig,
      '--output-dill',
      options.outputDill,
    ];
  }

  // Serializes everything on stdin/stdout: an interleaved compileExpression
  // and recompile would corrupt request framing and incremental state.
  Future<void> _lock = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() body) {
    final result = _lock.then((_) => body());
    // Swallow the error on this chain only, so one failed request doesn't
    // wedge later ones; the caller still sees it via [result].
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  String get _entrypointUri => _compilerUri(Uri.file(options.entrypoint));

  String _compilerUri(Uri uri) =>
      _packageUris?.toPackageUri(uri)?.toString() ?? uri.toString();

  Future<String> compile() => _serialized(() async {
    await _send('compile $_entrypointUri\n');
    return _readCompilationResult();
  });

  Future<String> recompile({required List<String> invalidated}) =>
      _serialized(() => _recompile(invalidated));

  Future<String> _recompile(List<String> invalidated) async {
    final boundaryToken = DateTime.now().microsecondsSinceEpoch.toRadixString(
      16,
    );
    final sb = StringBuffer()
      ..write('recompile $_entrypointUri $boundaryToken\n');
    for (final uri in invalidated) {
      sb.write('${_compilerUri(Uri.parse(uri))}\n');
    }
    sb.write('$boundaryToken\n');
    await _send(sb.toString());
    return _readCompilationResult();
  }

  /// Resets the incremental compiler so the next [recompile] emits a full
  /// kernel instead of a delta. Required before a hot restart, which needs a
  /// complete `mainScript`.
  Future<void> reset() => _serialized(() => _send('reset\n'));

  /// Commit the latest output as the next incremental baseline.
  Future<void> accept() => _serialized(() => _send('accept\n'));

  Future<void> reject() => _serialized(_reject);

  Future<void> _reject() async {
    await _send('reject\n');
    await _readResponse(acknowledgement: true);
  }

  Future<String> _readCompilationResult() async {
    try {
      return await _readResultBoundary();
    } on FrontendServerException catch (error) {
      if (error.compilationFailed) await _reject();
      rethrow;
    }
  }

  /// Compiles [expression] into an expression kernel and returns its bytes.
  ///
  /// Serves the VM Service `compileExpression` extension used by DevTools
  /// `evaluate`.
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
    return File(await _readResultBoundary(expectSources: false)).readAsBytes();
  });

  Future<void> close() async {
    // Try a polite quit first so frontend_server can flush, but never wait
    // forever for it.
    try {
      await _send('quit\n').timeout(const Duration(milliseconds: 500));
    } on Object catch (_) {
      options.onTrace?.call('[frontend_server] quit failed or timed out');
    }
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
    } on Object catch (_) {
      options.onTrace?.call(
        '[frontend_server] stdin close failed or timed out',
      );
    }
    await _queue?.cancel(immediate: true);
    _queue = null;
  }

  Future<void> _send(String s) async {
    final sink = _sink;
    if (sink == null) {
      throw FrontendServerException('frontend_server closed unexpectedly');
    }
    sink.write(s);
    await sink.flush();
  }

  Future<String> _readResultBoundary({bool expectSources = true}) async =>
      (await _readResponse(expectSources: expectSources))!;

  Future<String?> _readResponse({
    bool expectSources = true,
    bool acknowledgement = false,
  }) {
    final queue = _queue;
    if (queue == null) {
      throw FrontendServerException('frontend_server closed unexpectedly');
    }
    return _parseResponse(
      queue,
      expectSources: expectSources,
      acknowledgement: acknowledgement,
    ).timeout(
      const Duration(seconds: 60),
      onTimeout: () async {
        await close();
        throw FrontendServerException('frontend_server: no result within 60s');
      },
    );
  }

  static Future<String> parseResultBoundary(
    StreamQueue<String> queue, {
    bool expectSources = true,
  }) async => (await _parseResponse(queue, expectSources: expectSources))!;

  static Future<void> parseRejectBoundary(StreamQueue<String> queue) async {
    await _parseResponse(queue, acknowledgement: true);
  }

  static Future<String?> _parseResponse(
    StreamQueue<String> queue, {
    bool expectSources = true,
    bool acknowledgement = false,
  }) async {
    String? boundary;
    var sources = false;
    final diagnostics = <String>[];
    while (await queue.hasNext) {
      final line = await queue.next;
      if (boundary == null) {
        if (line.startsWith('result ')) {
          boundary = line.substring('result '.length).trim();
          if (boundary.isEmpty) {
            throw FrontendServerException('frontend_server: empty boundary');
          }
        }
        continue;
      }
      if (line == boundary) {
        if (acknowledgement) return null;
        if (expectSources && !sources) {
          sources = true;
          continue;
        }
        throw FrontendServerException(
          'frontend_server: compilation produced no kernel'
          '${diagnostics.isEmpty ? '' : '\n${diagnostics.join('\n')}'}',
          compilationFailed: true,
        );
      }
      if (line.startsWith('$boundary ')) {
        final parts = line
            .substring(boundary.length)
            .trim()
            .split(_whitespacePattern);
        final errorCount = int.tryParse(parts.last);
        if (parts.length < 2 || errorCount == null || errorCount < 0) {
          throw FrontendServerException(
            'frontend_server: malformed result: $line',
          );
        }
        if (errorCount != 0) {
          throw FrontendServerException(
            'frontend_server: compilation failed with $errorCount error(s)'
            '${diagnostics.isEmpty ? '' : '\n${diagnostics.join('\n')}'}',
            errorCount: errorCount,
            compilationFailed: true,
          );
        }
        if (acknowledgement) {
          throw FrontendServerException(
            'frontend_server: expected reject acknowledgement',
          );
        }
        return parts.take(parts.length - 1).join(' ');
      }
      if (!sources) diagnostics.add(line);
    }
    throw FrontendServerException('frontend_server closed unexpectedly');
  }

  /// Builds the stdin payload for `compile-expression`: header, expression,
  /// then five boundary-terminated lists, then the context. Order and count
  /// are fixed — a missing terminator desynchronises the compiler.
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
