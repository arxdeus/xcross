import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/swiftpm/artifact_copy_policy.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';

final class WindowsSwiftPmArtifactCopyPolicy
    implements SwiftPmArtifactCopyPolicy {
  const WindowsSwiftPmArtifactCopyPolicy({
    required this.fileSystem,
    required this.startProcess,
  });
  final SwiftPmArtifactFileSystem fileSystem;
  final StartBinaryCopy startProcess;
  @override
  Future<void> copy({
    required String source,
    required Directory destination,
    required Duration timeout,
  }) async {
    final temporary = destination;
    final process = await startProcess('robocopy', [
      fileSystem.processPath(source),
      fileSystem.processPath(temporary.path),
      '/E',
      '/R:0',
      '/W:0',
      '/MT:8',
      '/NFL',
      '/NDL',
      '/NJH',
      '/NJS',
      '/NP',
    ]);
    final output = BinaryCopyDiagnosticCollector(process.stdout);
    final error = BinaryCopyDiagnosticCollector(process.stderr);
    final exitCode = await _awaitCopyProcess(
      process: process,
      output: output,
      error: error,
      source: source,
      temporary: temporary,
      timeout: timeout,
    );
    if (exitCode > 7) {
      throw FileSystemException(
        'SwiftPM binary artifact copy failed with exit code $exitCode: '
        '${_boundedDiagnostic(error.text, output.text)}',
        source,
      );
    }
  }

  Future<int> _awaitCopyProcess({
    required BinaryCopyProcess process,
    required BinaryCopyDiagnosticCollector output,
    required BinaryCopyDiagnosticCollector error,
    required String source,
    required Directory temporary,
    required Duration timeout,
  }) async {
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      await _handleCopyTimeout(
        process: process,
        output: output,
        error: error,
        source: source,
        temporary: temporary,
        timeout: timeout,
      );
      rethrow;
    }
    await output.done;
    await error.done;
    return exitCode;
  }

  Future<void> _handleCopyTimeout({
    required BinaryCopyProcess process,
    required BinaryCopyDiagnosticCollector output,
    required BinaryCopyDiagnosticCollector error,
    required String source,
    required Directory temporary,
    required Duration timeout,
  }) async {
    var killed = false;
    const grace = Duration(milliseconds: 100);
    var exitedDuringGrace = false;
    final failures = <String>[];
    for (var attempt = 0; attempt < 3 && !exitedDuringGrace; attempt++) {
      try {
        killed = process.kill() || killed;
      } on Object catch (failure) {
        failures.add('kill failed: $failure');
      }
      try {
        await process.exitCode.timeout(grace);
        exitedDuringGrace = true;
      } on TimeoutException {
        continue;
      } on Object catch (failure) {
        failures.add('exit observation failed: $failure');
      }
    }
    for (final collector in [output, error]) {
      try {
        await collector.stop();
      } on Object catch (failure) {
        failures.add('diagnostic cleanup failed: $failure');
      }
    }
    if (!exitedDuringGrace) {
      try {
        await fileSystem
            .file(p.join(temporary.path, '.xcross-live-copy-quarantine'))
            .writeAsString('retained: process ownership cannot be revalidated');
      } on Object catch (failure) {
        failures.add('quarantine marker failed: $failure');
      }
    }
    final message =
        'SwiftPM binary artifact copy timed out after $timeout; '
        'kill returned $killed; process '
        '${exitedDuringGrace ? 'exited' : 'did not exit'} during $grace grace period: '
        '${_boundedDiagnostic(error.text, output.text)}'
        '${failures.isEmpty ? '' : '\n${_boundedDiagnostic(failures.join('\n'))}'}';
    if (!exitedDuringGrace) throw SwiftPmLiveCopyException(message, source);
    throw FileSystemException(message, source);
  }

  static String _boundedDiagnostic(String primary, [String secondary = '']) {
    const limit = 1024;
    String clip(String value) =>
        value.length <= limit ? value : '${value.substring(0, limit)}…';
    return [
      clip(primary),
      clip(secondary),
    ].where((value) => value.isNotEmpty).join('\n');
  }
}

final class BinaryCopyDiagnosticCollector {
  BinaryCopyDiagnosticCollector(Stream<List<int>> stream) {
    _subscription = stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
          if (_buffer.length >= _limit) return;
          final remaining = _limit - _buffer.length;
          _buffer.write(
            chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
          );
        }, onDone: _done.complete);
  }

  static const _limit = 1024;
  final _buffer = StringBuffer();
  final _done = Completer<void>();
  late final StreamSubscription<String> _subscription;

  Future<void> get done => _done.future;
  String get text => _buffer.toString();

  Future<void> stop() async {
    await _subscription.cancel();
    if (!_done.isCompleted) _done.complete();
  }
}
