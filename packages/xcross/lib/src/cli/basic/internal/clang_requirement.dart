import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;

/// Locate a usable clang pair, including versioned binaries that are not the
/// default `clang` on PATH. Do not mistake an old unversioned clang for a new
/// versioned one.
final class ClangRequirement {
  static const minimum = 20;

  static int? majorVersion(String output) {
    final match = RegExp(
      r'\b(?:clang version|clang-[a-z]+ version)\s+(\d+)',
    ).firstMatch(output);
    return match == null ? null : int.parse(match.group(1)!);
  }

  static Future<String?> resolve({
    Future<String?> Function(String name, List<String> directories)? lookup,
    Future<String> Function(String executable)? version,
    List<String>? directories,
  }) async {
    final dirs =
        directories ??
        [
          ...Platform.environment['PATH']?.split(
                Platform.isWindows ? ';' : ':',
              ) ??
              <String>[],
          ...DarwinSdk.llvmToolDirs(),
        ];
    final find =
        lookup ??
        (name, dirs) => ProcessRunner.which(name, extraDirectories: dirs);
    final readVersion =
        version ??
        (executable) async {
          final result = await ProcessRunner.run(executable, ['--version']);
          return result.stdout;
        };
    final names = <String>{'clang'};
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      try {
        for (final entry in Directory(dir).listSync()) {
          final name = p.basename(entry.path);
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
      final executable = await find(name, dirs);
      if (executable == null) continue;
      try {
        if ((majorVersion(await readVersion(executable)) ?? 0) >= minimum) {
          // clang++ must come from the same installation, not an older PATH entry.
          final companion = p.join(
            p.dirname(executable),
            p
                .basename(executable)
                .replaceFirst(
                  RegExp('^clang', caseSensitive: false),
                  'clang++',
                ),
          );
          if (File(companion).existsSync() &&
              (majorVersion(await readVersion(companion)) ?? 0) >= minimum) {
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
