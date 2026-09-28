import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/flutter/errors.dart';

/// The frontend_server snapshot and the Dart runtime able to execute it.
@immutable
final class KernelCompiler {
  const KernelCompiler({
    required this.snapshot,
    required this.runtime,
    required this.runtimeName,
    required this.isAot,
  });

  final String snapshot;
  final String runtime;
  final String runtimeName;
  final bool isAot;
}

/// Warm-start bookkeeping for the persistent `app.dill` frontend_server
/// writes to, mirroring flutter_tools' `--incremental
/// --initialize-from-dill <outputDill>`: the incremental compiler only
/// invalidates changed *source* files, so it never notices a changed
/// `-D` define, `--flavor`, or entrypoint on its own. A key file written
/// beside the dill after every successful compile guards against silently
/// reusing a dill built with different compiler inputs.
abstract final class KernelWarmStart {
  /// Path of the key file that accompanies [outputDill].
  static String keyPathFor(String outputDill) => '$outputDill.key';

  /// The subset of a frontend_server argument list that should feed the
  /// warm-start key: everything except the `--output-dill` /
  /// `--initialize-from-dill` flags and their (always-identical, per-machine)
  /// path values.
  @visibleForTesting
  static List<String> argsForKey(List<String> args) {
    final result = <String>[];
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--output-dill' || arg == '--initialize-from-dill') {
        i++; // Skip the path value that follows.
        continue;
      }
      result.add(arg);
    }
    return result;
  }

  /// sha256 over the compiler args (minus output/initialize paths), the
  /// compiler runtime + snapshot paths, the engine hash, and the content of
  /// the `package_config.json` in use. Any of these changing means the
  /// existing `app.dill` cannot be trusted as an incremental-compile seed.
  static String computeKey({
    required List<String> args,
    required String runtime,
    required String snapshot,
    required String engineHash,
    required String packageConfigContent,
  }) {
    final buffer = StringBuffer();
    for (final arg in argsForKey(args)) {
      buffer.write(arg);
      buffer.write('\n');
    }
    buffer
      ..write(runtime)
      ..write('\n')
      ..write(snapshot)
      ..write('\n')
      ..write(engineHash)
      ..write('\n')
      ..write(packageConfigContent);
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }

  /// Runs [compile] to (re)produce `outputDill`, deleting a stale dill and
  /// key first when [warmStartKey] does not match what's on disk, and
  /// deleting both on failure (compile throws, or [outputDill] is missing
  /// afterwards) so a broken dill is never left behind for the next build to
  /// warm-start from. Writes the key only once [compile] succeeds and the
  /// dill exists.
  static Future<void> compileWithWarmStart({
    required String outputDill,
    required String warmStartKey,
    required Future<void> Function() compile,
  }) async {
    final keyFile = File(keyPathFor(outputDill));
    final dillFile = File(outputDill);

    final existingKey = keyFile.existsSync()
        ? keyFile.readAsStringSync()
        : null;
    if (existingKey != warmStartKey) {
      if (dillFile.existsSync()) dillFile.deleteSync();
      if (keyFile.existsSync()) keyFile.deleteSync();
    }

    void discard() {
      if (dillFile.existsSync()) dillFile.deleteSync();
      if (keyFile.existsSync()) keyFile.deleteSync();
    }

    try {
      await compile();
    } on Object {
      discard();
      rethrow;
    }
    if (!dillFile.existsSync()) {
      discard();
      throw FlutterBuildError(
        'FlutterDebugBundler: kernel snapshot did not produce $outputDill',
      );
    }

    keyFile.writeAsStringSync(warmStartKey);
  }
}
