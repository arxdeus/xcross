import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/shared/process/process.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/swiftpm/response_arguments.dart';

/// Win32 extended-length path prefix. Foundation mishandles it in some
/// directory copies, so copy inputs carrying it are rewritten.
const String _extendedPathPrefix = r'\\?\';

/// Win32 `MAX_PATH`: the longest path legacy (non-extended) APIs accept,
/// including the terminating NUL.
const int _legacyMaxPath = 260;

/// The CreateProcess command-line limit in UTF-16 units, including the
/// terminating NUL that [WindowsSwiftPlanRepair.windowsCommandLineLength]
/// counts, so staying below it keeps one unit of headroom.
const int _maxCommandLineLength = 32767;

/// Command lines at or above this length move into a response file. It
/// leaves headroom below [_maxCommandLineLength] for anything llbuild or the
/// compiler driver appends.
const int _responseFileThreshold = 28000;

/// Prefix of an llbuild plan (`*.yaml`) line holding one command's
/// JSON-encoded argv.
const String _llbuildArgsPrefix = '    args: ';

/// Scratch subdirectory holding content-addressed compiler response files.
const String _responseCacheDirectoryName = '.xcross-response';

/// Scratch subdirectory holding short junctions to long copy inputs.
const String _copyInputAliasDirectoryName = '.xcross-copy-inputs';

/// Unused response files are pruned only once they are this old.
const Duration _responseFileRetention = Duration(days: 7);

/// A duplicated extended drive prefix SwiftPM emits into JSON plans
/// (`\\?\C:\?\C:\`, JSON-escaped), which it cannot read back.
const String _duplicatedExtendedDrivePrefix = r'\\\\?\\C:\\?\\C:\\';

final RegExp _responseFileName = RegExp(r'^[a-f0-9]{64}\.rsp$');
final RegExp _driveRootPattern = RegExp(r'^[a-zA-Z]:\\');

const Set<String> _swiftCompilers = {'swiftc', 'swiftc.exe'};
const Set<String> _clangCompilers = {
  'clang',
  'clang.exe',
  'clang++',
  'clang++.exe',
};

/// Windows-only normalization of SwiftPM's generated build plans.
@internal
final class WindowsSwiftPlanRepair {
  WindowsSwiftPlanRepair(this.runner);
  final ProcessRunner runner;
  static int windowsCommandLineLength(List<String> arguments) =>
      arguments
          .map(SwiftPmResponseArguments.quoteWindowsArgument)
          .join(' ')
          .length +
      1;
  static bool isWindowsMountPointReparseOutput(String output) =>
      RegExp(r'0x0*a0000003\b', caseSensitive: false).hasMatch(output);

  Future<bool> repairWindowsGeneratedBuildFiles(
    String scratchPath,
    String targetBuildDir,
  ) async {
    final root = runner.host.fileSystem.directory(targetBuildDir);
    if (!root.existsSync()) return false;
    var changed = await repairWindowsSwiftResponseFiles(scratchPath);
    changed = await _repairJsonPlans(root, scratchPath) || changed;
    changed = await _repairResourceBundleAccessors(root) || changed;
    return changed;
  }

  Future<bool> _repairJsonPlans(Directory root, String scratchPath) async {
    var changed = false;
    final hostTriple = switch (runner.host.architecture) {
      'arm64' => 'aarch64-unknown-windows-msvc',
      'x64' => 'x86_64-unknown-windows-msvc',
      _ => null,
    };
    for (final json in [
      ..._filesUnder(root).where((file) => p.extension(file.path) == '.json'),
      if (hostTriple != null)
        runner.host.fileSystem.file(
          p.join(
            scratchPath,
            hostTriple,
            'debug',
            'plugin-tools-description.json',
          ),
        ),
    ]) {
      if (!json.existsSync()) continue;
      final original = await json.readAsString();
      var normalized = original.replaceAll(
        _duplicatedExtendedDrivePrefix,
        r'C:\\',
      );
      if (p.basename(json.path) == 'description.json') {
        normalized = normalizeWindowsDirectoryCopyInputs(normalized);
        normalized = await stageWindowsDirectoryCopyInputs(
          normalized,
          scratchPath,
        );
      }
      if (normalized != original) {
        await json.writeAsString(normalized);
        changed = true;
      }
    }
    return changed;
  }

  static Future<bool> _repairResourceBundleAccessors(Directory root) async {
    var changed = false;
    for (final accessor in _filesUnder(
      root,
    ).where((file) => p.basename(file.path) == 'resource_bundle_accessor.m')) {
      final original = await accessor.readAsString();
      final normalized = original
          .replaceAll(r'\', '/')
          .replaceAll(
            '#import <Foundation/Foundation.h>',
            '#include <Foundation/Foundation.h>',
          );
      if (normalized != original) {
        await accessor.writeAsString(normalized);
        changed = true;
      }
    }
    return changed;
  }

  static Iterable<File> _filesUnder(Directory root) =>
      root.listSync(recursive: true, followLinks: false).whereType<File>();

  /// llbuild's shell commands bypass compiler response-file fallback.
  /// Keep the generated graph intact, replacing only oversized compiler argv.
  Future<bool> repairWindowsSwiftResponseFiles(String scratchPath) async {
    var changed = false;
    for (final plan in _llbuildPlans(scratchPath)) {
      final lines = (await plan.readAsString()).split('\n');
      var repaired = false;
      for (var i = 0; i < lines.length; i++) {
        final replacement = await _externalizeLongCompilerArguments(
          lines[i],
          scratchPath,
        );
        if (replacement == null) continue;
        lines[i] = replacement;
        repaired = true;
      }
      if (repaired) {
        await plan.writeAsString(lines.join('\n'));
        changed = true;
      }
    }
    await _pruneWindowsResponseFiles(scratchPath);
    return changed;
  }

  /// The replacement for a plan [line] whose Swift or Clang argv is too long
  /// for CreateProcess, or null when the line needs no change.
  Future<String?> _externalizeLongCompilerArguments(
    String line,
    String scratchPath,
  ) async {
    // Malformed JSON propagates: this pass rewrites the plan, so it must not
    // silently skip a command line it failed to read.
    final decoded = _decodeLlbuildArgs(line);
    if (decoded == null || !decoded.every((arg) => arg is String)) {
      return null;
    }
    final args = decoded.cast<String>();
    if (args.isEmpty) return null;
    final tool = p.windows.basename(args.first).toLowerCase();
    final swift = _swiftCompilers.contains(tool);
    final clang = _clangCompilers.contains(tool);
    if ((!swift && !clang) ||
        windowsCommandLineLength(args) < _responseFileThreshold) {
      return null;
    }
    final contents = args
        .skip(1)
        .map(
          swift
              ? SwiftPmResponseArguments.quoteWindowsArgument
              : SwiftPmResponseArguments.quoteGnuArgument,
        )
        .join('\n');
    final digest = sha256.convert(utf8.encode(contents));
    final file = runner.host.fileSystem.file(
      p.join(_responseCacheDirectory(scratchPath), '$digest.rsp'),
    );
    await file.parent.create(recursive: true);
    if (!file.existsSync() || await file.readAsString() != contents) {
      await file.writeAsString(contents);
    }
    final shortened = [args.first, '@${p.absolute(file.path)}'];
    if (windowsCommandLineLength(shortened) >= _maxCommandLineLength) {
      throw FlutterBuildError('Compiler response-file path is too long');
    }
    return _encodeLlbuildArgs(shortened);
  }

  Future<void> _pruneWindowsResponseFiles(String scratchPath) async {
    final cache = runner.host.fileSystem.directory(
      _responseCacheDirectory(scratchPath),
    );
    if (!cache.existsSync()) return;
    // Plans reference response files by absolute path, so compare absolute
    // paths: a relative scratch path would otherwise never match and a still
    // referenced response file could be pruned once it is old enough.
    String canonical(String path) => p.normalize(p.absolute(path));
    final cachePath = canonical(cache.path);
    final referenced = <String>{};
    for (final plan in _llbuildPlans(scratchPath)) {
      for (final line in await plan.readAsLines()) {
        final decoded = _tryDecodeLlbuildArgs(line);
        if (decoded == null) continue;
        for (final reference in _responseFileReferences(decoded)) {
          final file = canonical(reference);
          if (p.isWithin(cachePath, file)) referenced.add(file);
        }
      }
    }
    final cutoff = DateTime.now().subtract(_responseFileRetention);
    for (final file in cache.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (!_responseFileName.hasMatch(name) ||
          referenced.contains(canonical(file.path)) ||
          !file.lastModifiedSync().isBefore(cutoff)) {
        continue;
      }
      await file.delete();
    }
  }

  /// The top-level llbuild plans (`*.yaml`) SwiftPM wrote to [scratchPath].
  Iterable<File> _llbuildPlans(String scratchPath) => runner.host.fileSystem
      .directory(scratchPath)
      .listSync()
      .whereType<File>()
      .where((plan) => p.extension(plan.path) == '.yaml');

  /// Where [repairWindowsSwiftResponseFiles] keeps response files.
  static String _responseCacheDirectory(String scratchPath) =>
      p.join(scratchPath, _responseCacheDirectoryName);

  /// The argv of an llbuild plan `    args: [...]` [line], or null when the
  /// line is not an argv line or its JSON is not a list.
  ///
  /// Throws [FormatException] when the argv JSON is malformed.
  static List<dynamic>? _decodeLlbuildArgs(String line) {
    if (!line.startsWith('$_llbuildArgsPrefix[')) return null;
    final decoded = jsonDecode(line.substring(_llbuildArgsPrefix.length));
    return decoded is List ? decoded : null;
  }

  /// Like [_decodeLlbuildArgs], treating malformed JSON as a non-argv line.
  static List<dynamic>? _tryDecodeLlbuildArgs(String line) {
    try {
      return _decodeLlbuildArgs(line);
    } on FormatException {
      return null;
    }
  }

  /// An llbuild plan argv line for [arguments].
  static String _encodeLlbuildArgs(List<String> arguments) =>
      '$_llbuildArgsPrefix${jsonEncode(arguments)}';

  /// The paths named by `@file` response-file arguments in [arguments].
  static Iterable<String> _responseFileReferences(List<dynamic> arguments) =>
      arguments
          .whereType<String>()
          .where((argument) => argument.startsWith('@'))
          .map((argument) => argument.substring(1));

  /// Every line of each response file the llbuild [manifest] text references
  /// inside this build's response cache under [scratchPath].
  ///
  /// Symlinks and files not named like a generated response file are
  /// ignored. Returns null when a referenced response file cannot be read.
  /// Foundation's directory copy mishandles extended drive paths as file URLs
  /// on Windows. Keep llbuild's node identities intact and normalize only the
  /// directory source passed by CopyCommand to FileManager in description.json.
  String normalizeWindowsDirectoryCopyInputs(String description) {
    final decoded = jsonDecode(description);
    var changed = false;
    for (final input in _directoryCopyInputs(decoded)) {
      final source = _extendedDriveSource(input['name']);
      if (source == null || !_windowsCopyTreeFitsLegacyPaths(source)) {
        continue;
      }
      input['name'] = source;
      changed = true;
    }
    return changed ? _encodeDescription(decoded) : description;
  }

  /// Foundation's copy command cannot read some extended-length directory
  /// inputs on Windows. Present only those inputs through a short junction
  /// inside this build's scratch directory; vendor sources stay unchanged.
  Future<String> stageWindowsDirectoryCopyInputs(
    String description,
    String scratchPath,
  ) async {
    final decoded = jsonDecode(description);
    var changed = false;
    for (final input in _directoryCopyInputs(decoded)) {
      final name = input['name'];
      final source = _extendedDriveSource(name);
      if (source == null) continue;
      if (_windowsCopyTreeFitsLegacyPaths(source)) continue;
      if (!runner.host.fileSystem.directory(name as String).existsSync()) {
        continue;
      }
      final digest = sha256.convert(utf8.encode(p.windows.normalize(source)));
      final alias = p.join(
        scratchPath,
        _copyInputAliasDirectoryName,
        digest.toString().substring(0, 24),
      );
      await _ensureWindowsDirectoryCopyAlias(alias, source);
      if (!_windowsCopyTreeFitsLegacyPaths(alias)) {
        throw FlutterBuildError(
          'SwiftPM directory copy path remains too long after staging: $alias',
        );
      }
      input['name'] = alias;
      changed = true;
    }
    return changed ? _encodeDescription(decoded) : description;
  }

  /// Each mutable `{"kind": "directory", ...}` input of every copy command in
  /// a decoded SwiftPM `description.json`. Malformed parts are skipped.
  static Iterable<Map<String, dynamic>> _directoryCopyInputs(
    Object? description,
  ) sync* {
    if (description is! Map<String, dynamic>) return;
    final commands = description['copyCommands'];
    if (commands is! Map<String, dynamic>) return;
    for (final command in commands.values) {
      if (command is! Map<String, dynamic>) continue;
      final inputs = command['inputs'];
      if (inputs is! List<dynamic>) continue;
      for (final input in inputs) {
        if (input is Map<String, dynamic> && input['kind'] == 'directory') {
          yield input;
        }
      }
    }
  }

  /// [name] without its extended-length prefix when it is an extended drive
  /// path such as `\\?\C:\...`, otherwise null. UNC forms are not handled.
  static String? _extendedDriveSource(Object? name) {
    if (name is! String || !name.startsWith(_extendedPathPrefix)) return null;
    final source = name.substring(_extendedPathPrefix.length);
    return _driveRootPattern.hasMatch(source) ? source : null;
  }

  static String _encodeDescription(Object? description) =>
      const JsonEncoder.withIndent('  ').convert(description);

  Future<void> _ensureWindowsDirectoryCopyAlias(
    String alias,
    String source,
  ) async {
    final resolved = await runner.host.fileSystem
        .directory(source)
        .resolveSymbolicLinks();
    final target = p.windows.normalize(
      _extendedDriveSource(resolved) ?? resolved,
    );
    final aliasDirectory = runner.host.fileSystem.directory(alias);
    if (!runner.host.fileSystem.file(alias).existsSync() &&
        !runner.host.fileSystem.directory(alias).existsSync() &&
        !runner.host.fileSystem.link(alias).existsSync()) {
      await aliasDirectory.parent.create(recursive: true);
      // PowerShell receives the paths as quoted literals, unlike cmd /c
      // mklink, which expands %NAME% and interprets & in user directory names.
      // New-Item treats brackets in the target as wildcard syntax.
      String literal(String path) => "'${path.replaceAll("'", "''")}'";
      final literalTarget = target.replaceAll('[', '`[').replaceAll(']', '`]');
      final result = await runner.run(await runner.locateTool('powershell.exe'), [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'New-Item -ItemType Junction -Path ${literal(alias)} -Target ${literal(literalTarget)} | Out-Null',
      ]);
      if (result.exitCode != 0 &&
          (!runner.host.fileSystem.file(alias).existsSync() &&
              !runner.host.fileSystem.directory(alias).existsSync() &&
              !runner.host.fileSystem.link(alias).existsSync())) {
        throw FlutterBuildError(
          'Could not stage long SwiftPM directory copy: ${result.stderr}',
        );
      }
    }
    final mount = await runner.run(await runner.locateTool('fsutil.exe'), [
      'reparsepoint',
      'query',
      alias,
    ]);
    final aliasTarget = p.windows.normalize(
      await runner.host.fileSystem.link(alias).target(),
    );
    if (mount.exitCode != 0 ||
        !isWindowsMountPointReparseOutput(mount.stdout) ||
        !p.windows.equals(
          _extendedDriveSource(aliasTarget) ?? aliasTarget,
          target,
        )) {
      throw FlutterBuildError(
        'Refusing a changed SwiftPM directory copy alias: $alias',
      );
    }
  }

  bool _windowsCopyTreeFitsLegacyPaths(String root) {
    if (root.length >= _legacyMaxPath) return false;
    final directory = runner.host.fileSystem.directory(root);
    if (!directory.existsSync()) return true;
    return directory
        .listSync(recursive: true, followLinks: false)
        .every((entry) => entry.path.length < _legacyMaxPath);
  }
}
