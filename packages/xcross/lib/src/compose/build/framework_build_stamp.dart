import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Records the inputs of a Kotlin/Native framework build so an unchanged
/// rebuild can be skipped.
///
/// The `konanc` step is by far the most expensive part of a Compose iOS
/// build: measured at ~133s of a ~147s cycle for a one-word edit on the
/// sample app, because Kotlin/Native compiles the whole program ahead of
/// time. Gradle already skips its own work via `UP-TO-DATE`, but xcross
/// invoked `konanc` unconditionally afterwards, so a `--watch` restart with
/// no Kotlin change still paid the full price.
///
/// The stamp covers the module klib, every dependency klib, and the exact
/// compiler argument list, since a changed flag (configuration, bundle id)
/// must invalidate just as surely as a changed source.
final class FrameworkBuildStamp {
  const FrameworkBuildStamp({required this.stampPath});

  /// Where the stamp for this framework output lives.
  factory FrameworkBuildStamp.forFramework(String frameworkPath) =>
      FrameworkBuildStamp(
        stampPath: p.join(
          p.dirname(frameworkPath),
          '.${p.basename(frameworkPath)}.xcross-stamp',
        ),
      );

  final String stampPath;

  /// Whether [frameworkPath] already exists and was built from exactly these
  /// inputs. False on any doubt: a wrong "up to date" ships a stale binary to
  /// the device, which is far worse than an unnecessary rebuild.
  bool isUpToDate({
    required String frameworkPath,
    required List<String> inputs,
    required List<String> arguments,
  }) {
    if (!Directory(frameworkPath).existsSync()) return false;
    final file = File(stampPath);
    if (!file.existsSync()) return false;
    try {
      return file.readAsStringSync() ==
          compute(inputs: inputs, arguments: arguments);
    } on Object catch (_) {
      return false;
    }
  }

  /// Record the current inputs as the built state.
  void write({required List<String> inputs, required List<String> arguments}) {
    try {
      File(stampPath)
        ..createSync(recursive: true)
        ..writeAsStringSync(compute(inputs: inputs, arguments: arguments));
    } on Object catch (_) {
      // A stamp that cannot be written only costs a rebuild next time.
    }
  }

  /// Remove the stamp so the next build always runs. Called before compiling
  /// so an interrupted or failed run cannot leave a stamp claiming success.
  void invalidate() {
    try {
      final file = File(stampPath);
      if (file.existsSync()) file.deleteSync();
    } on Object catch (_) {}
  }

  /// Digest of every input file's content plus the compiler arguments.
  ///
  /// Content hashing rather than mtime: Gradle rewrites klibs it did not
  /// semantically change, and mtime is unreliable on virtiofs/WSL mounts.
  String compute({
    required List<String> inputs,
    required List<String> arguments,
  }) {
    // Hash each input to a small digest first, then hash the digests: this
    // keeps peak memory flat even though the dependency klibs total hundreds
    // of megabytes.
    final parts = <String>[...arguments];
    for (final path in [...inputs]..sort()) {
      final file = File(path);
      if (file.existsSync()) {
        parts.add('$path:${sha256.convert(file.readAsBytesSync())}');
      } else {
        // A klib can be a directory (unpacked); fold its files in order so a
        // change inside it still invalidates.
        final directory = Directory(path);
        if (directory.existsSync()) {
          final files =
              directory
                  .listSync(recursive: true, followLinks: false)
                  .whereType<File>()
                  .toList()
                ..sort((a, b) => a.path.compareTo(b.path));
          for (final entry in files) {
            final relative = p.relative(entry.path, from: path);
            parts.add(
              '$path/$relative:${sha256.convert(entry.readAsBytesSync())}',
            );
          }
        } else {
          // Missing input: never claim up to date.
          parts.add('$path:<missing>');
        }
      }
    }
    return sha256.convert(utf8.encode(parts.join('\u0000'))).toString();
  }
}
