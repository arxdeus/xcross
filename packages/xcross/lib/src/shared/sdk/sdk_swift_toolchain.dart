import 'dart:convert';
import 'dart:io';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/cli/basic/internal/swift_sibling_clang.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/shared/sdk/sdk_directory_copy.dart';
import 'package:xcross/src/shared/sdk/sdk_install_constants.dart';
import 'package:xcross/src/shared/sdk/sdk_json_file_writer.dart';

final class SdkSwiftToolchain<T extends PlatformHostInterface> {
  SdkSwiftToolchain(this.runner) : json = SdkJsonFileWriter(runner.host);
  final ProcessRunner<T> runner;
  final SdkJsonFileWriter<T> json;
  T get host => runner.host;
  Log get log => runner.log;
  p.Context get _paths => host.paths.context;
  Future<void> replaceClangBuiltinHeaders(
    String artifactRoot, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final sibling = await _swiftSiblingClang(locateTool ?? runner.locateTool);
    final source = await _clangBuiltinHeaderDir(
      sibling.clang,
      sibling.swift,
      runProcess ?? runner.run,
    );
    final destination = _paths.join(
      artifactRoot,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
      'clang',
      'include',
    );
    await _deleteAnyEntity(destination);
    await SdkDirectoryCopy(host).copy(source, destination);
    await _writeHostToolchainStamp(
      artifactRoot,
      sibling,
      runProcess ?? runner.run,
    );
  }

  Future<Map<String, String>> hostToolchainIdentity({
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final sibling = await _swiftSiblingClang(locateTool ?? runner.locateTool);
    return _identity(sibling, runProcess ?? runner.run);
  }

  Future<Map<String, String>> _identity(
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    return {
      'swift': sibling.swift,
      'version': await _toolchainVersion(sibling, run),
    };
  }

  Future<String> _toolchainVersion(
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    final bin = _paths.dirname(sibling.swift);
    final candidates = <String>[
      _paths.join(bin, runner.hostExecutableName('swift-frontend')),
      sibling.swift,
      sibling.clang,
    ];
    for (final candidate in candidates) {
      if (candidate != sibling.swift &&
          !host.fileSystem.file(candidate).existsSync()) {
        continue;
      }
      try {
        final printed = await run(candidate, const ['--version']);
        if (printed.exitCode != 0) continue;
        final output = printed.stdout.trim().isEmpty
            ? printed.stderr.trim()
            : printed.stdout.trim();
        // `swift --version` prints the version line plus a `Target:` line.
        // Only the first line names the compiler build that fixes the module
        // ABI, and keeping just it makes stamps written by different tools
        // (and different host triples) comparable.
        final version = sdkFirstToolchainLine(output);
        if (version.isNotEmpty) return version;
      } on Object catch (error) {
        log.logTrace('$candidate --version failed while stamping SDK: $error');
      }
    }
    return '';
  }

  Future<void> _writeHostToolchainStamp(
    String artifactRoot,
    SwiftSiblingClang sibling,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    final identity = await _identity(sibling, run);
    await json.write(
      _paths.join(artifactRoot, hostToolchainStampName),
      identity,
    );
  }

  Map<String, String>? readHostToolchainStamp(String artifactRoot) {
    final file = host.fileSystem.file(
      _paths.join(artifactRoot, hostToolchainStampName),
    );
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return {
        for (final entry in decoded.entries)
          '${entry.key}': '${entry.value ?? ''}',
      };
    } on Object catch (error) {
      log.logTrace('Unreadable host toolchain stamp at ${file.path}: $error');
      return null;
    }
  }

  Future<String?> hostToolchainMismatch(
    String artifactRoot, {
    Future<String> Function(String name)? locateTool,
    Future<CapturedProcess> Function(String executable, List<String> arguments)?
    runProcess,
  }) async {
    final recorded = readHostToolchainStamp(artifactRoot);
    if (recorded == null) return null;
    final Map<String, String> current;
    try {
      current = await hostToolchainIdentity(
        locateTool: locateTool,
        runProcess: runProcess,
      );
    } on Object catch (error) {
      log.logTrace('Could not identify the host Swift toolchain: $error');
      return null;
    }
    final recordedVersion = recorded['version'] ?? '';
    final currentVersion = current['version'] ?? '';
    // An empty version on either side means the comparison never happened,
    // so fall back to the path, which is always recorded.
    if (recordedVersion.isNotEmpty && currentVersion.isNotEmpty) {
      if (recordedVersion == currentVersion) return null;
      return 'The Darwin SDK was installed against Swift '
          '"${sdkFirstToolchainLine(recordedVersion)}" (${recorded['swift']}), but the '
          '`swift` now on PATH is "${sdkFirstToolchainLine(currentVersion)}" '
          '(${current['swift']}).';
    }
    if (recorded['swift'] == current['swift']) return null;
    return 'The Darwin SDK was installed against the Swift toolchain at '
        '"${recorded['swift']}", but `swift` now resolves to '
        '"${current['swift']}".';
  }

  static String mismatchGuidance(String? detail) => [
    if (detail != null) detail,
    _mismatchCause,
    _mismatchRemedy,
    '    xcross sdk install <path-to-Xcode.xip>',
  ].join('\n');

  Future<SwiftSiblingClang> _swiftSiblingClang(
    Future<String> Function(String name) locate,
  ) async {
    final String swift;
    try {
      swift = await locate('swift');
    } on Object {
      throw XcrossError(
        'Could not locate the selected Swift executable `swift` on PATH.',
      );
    }

    final String resolvedSwift;
    try {
      resolvedSwift = await host.fileSystem.file(swift).resolveSymbolicLinks();
    } on Object {
      throw XcrossError(
        'Could not resolve selected Swift executable "$swift".',
      );
    }

    final clang = _paths.join(
      _paths.dirname(resolvedSwift),
      runner.hostExecutableName('clang'),
    );
    if (!host.fileSystem.file(clang).existsSync()) {
      throw XcrossError(
        'Selected Swift executable "$resolvedSwift" has no sibling clang at '
        '"$clang".',
      );
    }
    return SwiftSiblingClang(clang: clang, swift: resolvedSwift);
  }

  Future<String> _clangBuiltinHeaderDir(
    String clang,
    String resolvedSwift,
    Future<CapturedProcess> Function(String, List<String>) run,
  ) async {
    CapturedProcess? printed;
    Object? failure;
    try {
      printed = await run(clang, const ['-print-resource-dir']);
    } on Object catch (error) {
      failure = error;
    }

    if (printed != null && printed.exitCode == 0) {
      final resourceDir = printed.stdout.trim();
      if (resourceDir.isNotEmpty) {
        final source = _paths.join(resourceDir, 'include');
        if (host.fileSystem.directory(source).existsSync()) return source;
      }
    }

    // Asking clang is only the fast path: a toolchain whose binaries cannot
    // even start still ships its builtin headers at a fixed spot, and nothing
    // about installing the SDK actually needs to run the compiler.
    final shipped = _shippedClangHeaderDir(clang);
    if (shipped != null) {
      log.logWarn(
        'clang -print-resource-dir failed; falling back to the headers '
        'shipped at "$shipped".${_clangFailureDetail(printed, failure)}',
      );
      return shipped;
    }

    throw XcrossError(
      'Could not locate clang builtin headers using sibling clang "$clang" '
      'selected for Swift "$resolvedSwift".'
      '${_clangFailureDetail(printed, failure)}',
    );
  }

  String? _shippedClangHeaderDir(String clang) {
    final lib = _paths.join(_paths.dirname(_paths.dirname(clang)), 'lib');
    final versions = host.fileSystem.directory(_paths.join(lib, 'clang'));
    final candidates = <String>[];
    if (versions.existsSync()) {
      final byVersion =
          versions
              .listSync()
              .whereType<Directory>()
              .map((entity) => _paths.basename(entity.path))
              .toList()
            ..sort(_compareClangVersions);
      candidates.addAll(
        byVersion.map(
          (version) => _paths.join(lib, 'clang', version, 'include'),
        ),
      );
    }
    candidates.add(_paths.join(lib, 'swift', 'clang', 'include'));
    for (final candidate in candidates) {
      if (host.fileSystem.directory(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static int _compareClangVersions(String a, String b) {
    final left = _versionSegments(a);
    final right = _versionSegments(b);
    for (var i = 0; i < left.length && i < right.length; i++) {
      final order = right[i].compareTo(left[i]);
      if (order != 0) return order;
    }
    return right.length.compareTo(left.length);
  }

  static List<int> _versionSegments(String version) => version
      .split('.')
      .map((segment) => int.tryParse(segment) ?? -1)
      .toList(growable: false);

  static String _clangFailureDetail(CapturedProcess? result, Object? failure) {
    if (result == null) return '\n$failure';
    final detail = <String>[
      '`clang -print-resource-dir` exited ${result.exitCode}.',
    ];
    for (final output in [result.stdout.trim(), result.stderr.trim()]) {
      if (output.isNotEmpty) detail.add(output);
    }
    final status = ProcessRunner.describeExitCode(result.exitCode);
    if (status != null) detail.add('That is $status.');
    if (result.exitCode == sdkStatusDllNotFound ||
        result.exitCode == sdkStatusDllNotFound - 0x100000000) {
      detail.add(
        'The Swift toolchain binaries cannot start because their runtime DLLs '
        'are not on PATH. Open a new terminal so the installer PATH applies, '
        r'or add %LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\usr\bin to '
        'PATH.',
      );
    }
    return '\n${detail.join('\n')}';
  }

  Future<void> _deleteAnyEntity(String path) async {
    final type = host.fileSystem.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await host.fileSystem.directory(path).delete(recursive: true);
      case FileSystemEntityType.link:
        await host.fileSystem.link(path).delete();
      case FileSystemEntityType.file:
        await host.fileSystem.file(path).delete();
      default:
    }
  }

  static const _mismatchCause =
      'The Darwin SDK bundle carries Swift module interfaces that only the '
      'toolchain it was installed with can compile, so switching Swift '
      'versions (swiftly, mise, or a distro upgrade) invalidates it.';

  static const _mismatchRemedy =
      'Either select the Swift toolchain the SDK was installed with, or '
      'reinstall the SDK against the current one:';
}
