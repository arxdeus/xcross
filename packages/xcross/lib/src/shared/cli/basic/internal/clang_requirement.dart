import 'dart:io';

import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

/// Locate a usable clang pair, including versioned binaries that are not the
/// default `clang` on PATH. Do not mistake an old unversioned clang for a new
/// versioned one.
@internal
final class ClangRequirement {
  const ClangRequirement(this.runner);

  final ProcessRunner runner;

  static const minimum = 20;

  static int? majorVersion(String output) {
    final match = RegExp(
      r'\b(?:clang version|clang-[a-z]+ version)\s+(\d+)',
    ).firstMatch(output);
    return match == null ? null : int.parse(match.group(1)!);
  }

  Future<String?> resolve({
    Iterable<String> llvmDirectories = const [],
    List<String>? directories,
  }) async {
    final dirs =
        directories ??
        [
          ...runner.host.environment.splitPathList(
            runner.environmentValue(runner.effectiveEnvironment, 'PATH') ?? '',
          ),
          ...llvmDirectories,
        ];
    final names = <String>{'clang'};
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      try {
        for (final entry in runner.host.fileSystem.directory(dir).listSync()) {
          final name = runner.host.paths.context.basename(entry.path);
          if (RegExp(
            r'^clang-\d+(?:\.exe)?$',
            caseSensitive: false,
          ).hasMatch(name)) {
            names.add(name);
          }
        }
      } on FileSystemException {
        // A PATH entry can disappear or be inaccessible.
      }
    }
    final ordered = names.toList()
      ..sort((a, b) {
        int number(String name) =>
            int.tryParse(
              RegExp(r'clang-(\d+)').firstMatch(name)?.group(1) ?? '',
            ) ??
            0;
        return number(b).compareTo(number(a));
      });
    for (final name in ordered) {
      final executable = await runner.which(name, extraDirectories: dirs);
      if (executable == null) continue;
      try {
        if ((majorVersion(
                  (await runner.run(executable, ['--version'])).stdout,
                ) ??
                0) >=
            minimum) {
          // clang++ must come from the same installation, not an older PATH entry.
          final companion = runner.host.paths.context.join(
            runner.host.paths.context.dirname(executable),
            runner.host.paths.context
                .basename(executable)
                .replaceFirst(
                  RegExp('^clang', caseSensitive: false),
                  'clang++',
                ),
          );
          if (runner.host.fileSystem.file(companion).existsSync() &&
              (majorVersion(
                        (await runner.run(companion, ['--version'])).stdout,
                      ) ??
                      0) >=
                  minimum) {
            return executable;
          }
        }
      } on Object {
        // Broken candidates do not prevent checking another installation.
      }
    }
    return null;
  }
}
