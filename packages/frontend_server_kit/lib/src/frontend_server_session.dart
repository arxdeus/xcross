import 'dart:async';

import 'package:async/async.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:frontend_server_kit/src/errors.dart';
import 'package:frontend_server_kit/src/frontend_server_options.dart';
import 'package:frontend_server_kit/src/package_uris.dart';
import 'package:frontend_server_kit/src/shared/process/compiler_transport.dart';
import 'package:path/path.dart' as p;

/// Drives a persistent `frontend_server` subprocess over its stdin/stdout
/// protocol, producing incremental kernel diffs for hot reload.
final class FrontendServerSession {
  FrontendServerSession(
    this.options, {
    required this.processFactory,
    required this.fileSystem,
    required this.paths,
    required this.packageUriLoader,
    required this.diagnostics,
  }) {
    if (!identical(fileSystem, packageUriLoader.fileSystem) ||
        !identical(paths, packageUriLoader.paths)) {
      throw ArgumentError(
        'package URI loader must use the session filesystem and paths',
      );
    }
  }

  final PackageUriLoader packageUriLoader;
  final CompilerProcessFactory processFactory;
  final HostFileSystemInterface fileSystem;
  final p.Context paths;
  final void Function(String) diagnostics;
  StreamSubscription<String>? _diagnosticsSubscription;

  static final _whitespacePattern = RegExp(r'\s+');

  final FrontendServerOptions options;

  CompilerTransport? _process;

  PackageUris? _packageUris;

  // StreamQueue holds the subscription so repeated hasNext/next works across
  // compile rounds; a plain `await for` would cancel it on early return.
  StreamQueue<String>? _queue;

  Future<void>? _starting;
  Future<void>? _closing;

  Future<void> spawn() {
    if (_process != null || _starting != null || _closing != null) {
      return Future.error(
        FrontendServerException('frontend_server already running'),
      );
    }
    return _starting = _spawn().whenComplete(() => _starting = null);
  }

  Future<void> _spawn() async {
    _packageUris = await packageUriLoader.load(options.packageConfig);

    final args = _spawnArguments();
    await fileSystem
        .directory(paths.dirname(options.outputDill))
        .create(recursive: true);

    options.onTrace?.call(
      '[frontend_server] running: ${options.dart} ${args.join(' ')}',
    );
    if (_process != null) {
      throw FrontendServerException('frontend_server already running');
    }
    final proc = await processFactory.start(options.dart, args);
    _process = proc;
    _queue = StreamQueue<String>(proc.output);
    _diagnosticsSubscription = proc.diagnostics.listen(diagnostics);
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

  String get _entrypointUri =>
      _compilerUri(paths.toUri(paths.absolute(options.entrypoint)));

  String _compilerUri(Uri uri) =>
      _packageUris?.toPackageUri(uri)?.toString() ?? uri.toString();

  Future<String> compile() => _serialized(() async {
    await _send('compile $_entrypointUri\n');
    return _readResultBoundary();
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
    return _readResultBoundary();
  }

  /// Resets the incremental compiler so the next [recompile] emits a full
  /// kernel instead of a delta. Required before a hot restart, which needs a
  /// complete `mainScript`.
  Future<void> reset() => _serialized(() => _send('reset\n'));

  /// Commit the latest output as the next incremental baseline.
  Future<void> accept() => _serialized(() => _send('accept\n'));

  Future<void> reject() => _serialized(() => _send('reject\n'));

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
    return fileSystem.file(await _readResultBoundary()).readAsBytes();
  });

  Future<void> close() =>
      _closing ??= _close().whenComplete(() => _closing = null);

  Future<void> _close() async {
    await _starting;
    final process = _process;
    _process = null;
    await _diagnosticsSubscription?.cancel();
    _diagnosticsSubscription = null;
    await _queue?.cancel(immediate: true);
    _queue = null;
    await process?.close();
  }

  Future<void> _send(String s) async {
    final process = _process;
    if (process == null) {
      throw FrontendServerException('frontend_server closed unexpectedly');
    }
    await process.send(s);
  }

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

  /// Parses `result <boundary>\n...\n<boundary> <dill> <errCount>` from
  /// [queue] and returns the local dill path. Exposed for tests of the line
  /// protocol framing.
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
        // The boundary is printed alone first, then again with the dill path
        // and error count; skip the bare echo.
        final rest = line.substring(boundary.length).trim();
        if (rest.isEmpty) continue;
        final parts = rest.split(_whitespacePattern);
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
