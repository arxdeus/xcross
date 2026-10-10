import 'dart:io';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:cli_kit/shared/process/process_models.dart';
import 'package:darwin_sdk_kit/shared/toolchain/darwin_toolchain_resolver.dart';
import 'package:meta/meta.dart';

/// Writes dSYM bundles with `dsymutil`, as flutter_tools does for profile and
/// release builds.
///
/// Every `dsymutil` on `PATH` and in the LLVM tool directories is tried in
/// turn, those beside a Swift toolchain last: some toolchains ship an
/// assertion-enabled build that crashes on the DWARF `gen_snapshot` emits.
/// The first one that works is tried first afterwards. A dSYM is best
/// effort: without a working `dsymutil` the build warns once and ships none.
@internal
final class AppleDebugSymbols<T extends PlatformHostInterface> {
  AppleDebugSymbols({required this.runner, required this.toolchain}) {
    if (!identical(runner.host, toolchain.host)) {
      throw ArgumentError('Debug symbols require one coherent host instance');
    }
  }

  final ProcessRunner<T> runner;
  final DarwinToolchainResolver<T> toolchain;
  T get host => runner.host;

  String? _working;
  bool _warned = false;

  /// Writes the dSYM of [binary] to [dsym], replacing any earlier one.
  /// Returns whether a `dsymutil` succeeded; otherwise no [dsym] is left.
  Future<bool> extract(String binary, String dsym) async {
    final name = host.paths.context.basename(dsym);
    final candidates = await _candidates();
    final failures = <String>[];
    for (final candidate in candidates) {
      await _delete(dsym);
      final failure = await _run(candidate, binary, dsym);
      if (failure == null) {
        _working = candidate;
        return true;
      }
      runner.log.logTrace('dsymutil: $candidate failed for $binary: $failure');
      failures.add('  $candidate $failure');
    }
    await _delete(dsym);
    _warn(
      candidates.isEmpty
          ? 'dsymutil not found; no $name is produced. Install LLVM '
                '(`xcross setup`) to get dSYMs.'
          : 'No $name is produced; every dsymutil failed:\n'
                '${failures.join('\n')}\n'
                'Assertion-enabled dsymutil builds, such as the one in some '
                'Swift toolchains, crash on Dart debug info. Install an LLVM '
                'release (`xcross setup`) to get dSYMs.',
    );
    return false;
  }

  void _warn(String message) {
    if (_warned) {
      runner.log.logTrace(message);
      return;
    }
    _warned = true;
    runner.log.logWarn(message);
  }

  Future<List<String>> _candidates() async {
    final found = await runner.whichAll(
      'dsymutil',
      extraDirectories: toolchain.llvmToolDirs(),
    );
    final working = _working;
    return [
      ?working,
      ...found.where((path) => path != working && !_besideSwift(path)),
      ...found.where((path) => path != working && _besideSwift(path)),
    ];
  }

  bool _besideSwift(String path) => host.fileSystem
      .file(
        host.paths.context.join(
          host.paths.context.dirname(path),
          host.paths.executableName('swift'),
        ),
      )
      .existsSync();

  /// Why [dsymutil] wrote no dSYM, or `null` when it did.
  Future<String?> _run(String dsymutil, String binary, String dsym) async {
    final CapturedProcess result;
    try {
      result = await runner.run(dsymutil, ['-o', dsym, binary]);
    } on ProcessException catch (error) {
      return 'could not start: ${error.message}';
    }
    final code = result.exitCode;
    if (code == 0) {
      return host.fileSystem.directory(dsym).existsSync()
          ? null
          : 'exited without writing $dsym';
    }
    final lines = [
      for (final line in result.stderr.split('\n'))
        if (line.trim() case final trimmed when trimmed.isNotEmpty) trimmed,
    ];
    final detail =
        lines.where(_isDiagnostic).firstOrNull ?? lines.firstOrNull ?? '';
    final exit = runner.crashed(code)
        ? 'crashed (${runner.describeExitCode(code) ?? 'exit code $code'})'
        : 'exited with code $code';
    return detail.isEmpty ? exit : '$exit: $detail';
  }

  static bool _isDiagnostic(String line) =>
      line.contains('UNREACHABLE') ||
      line.contains('Assertion') ||
      line.contains('error:');

  Future<void> _delete(String dsym) async {
    final directory = host.fileSystem.directory(dsym);
    if (directory.existsSync()) await directory.delete(recursive: true);
  }
}
