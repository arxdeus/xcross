import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/swiftpm_binary_artifact_preparer.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Windows-only normalization of SwiftPM's generated build plans.
abstract final class WindowsSwiftPlanRepair {
  static Future<bool> repairWindowsGeneratedBuildFiles(
    String scratchPath,
    String targetBuildDir, {
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return false;
    final root = Directory(targetBuildDir);
    if (!root.existsSync()) return false;
    var changed = await repairWindowsSwiftResponseFiles(
      scratchPath,
      windows: true,
    );
    for (final json in [
      ...root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => p.extension(file.path) == '.json'),
      File(
        p.join(
          scratchPath,
          'x86_64-unknown-windows-msvc',
          'debug',
          'plugin-tools-description.json',
        ),
      ),
    ]) {
      if (!json.existsSync()) continue;
      final original = await json.readAsString();
      var normalized = original.replaceAll(r'\\\\?\\C:\\?\\C:\\', r'C:\\');
      if (p.basename(json.path) == 'description.json') {
        normalized = normalizeWindowsDirectoryCopyInputs(normalized);
        normalized = await stageWindowsDirectoryCopyInputs(
          normalized,
          scratchPath,
          windows: true,
        );
      }
      if (normalized != original) {
        await json.writeAsString(normalized);
        changed = true;
      }
    }
    for (final accessor
        in root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where(
              (file) => p.basename(file.path) == 'resource_bundle_accessor.m',
            )) {
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

  /// llbuild's shell commands bypass compiler response-file fallback.
  /// Keep the generated graph intact, replacing only oversized compiler argv.
  static Future<bool> repairWindowsSwiftResponseFiles(
    String scratchPath, {
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return false;
    var changed = false;
    for (final plan in Directory(scratchPath).listSync().whereType<File>()) {
      if (p.extension(plan.path) != '.yaml') continue;
      final original = await plan.readAsString();
      final lines = original.split('\n');
      var repaired = false;
      for (var i = 0; i < lines.length; i++) {
        const prefix = '    args: ';
        if (!lines[i].startsWith('$prefix[')) continue;
        final decoded = jsonDecode(lines[i].substring(prefix.length));
        if (decoded is! List || !decoded.every((arg) => arg is String)) {
          continue;
        }
        final args = decoded.cast<String>();
        if (args.isEmpty) continue;
        final tool = p.windows.basename(args.first).toLowerCase();
        final swift = {'swiftc', 'swiftc.exe'}.contains(tool);
        final clang = {
          'clang',
          'clang.exe',
          'clang++',
          'clang++.exe',
        }.contains(tool);
        if ((!swift && !clang) || windowsCommandLineLength(args) < 28000) {
          continue;
        }
        final contents = args
            .skip(1)
            .map(swift ? quoteWindowsArgument : quoteGnuArgument)
            .join('\n');
        final digest = sha256.convert(utf8.encode(contents));
        final file = File(
          p.join(scratchPath, '.xcross-response', '$digest.rsp'),
        );
        await file.parent.create(recursive: true);
        if (!file.existsSync() || await file.readAsString() != contents) {
          await file.writeAsString(contents);
        }
        lines[i] =
            '$prefix${jsonEncode([args.first, '@${p.absolute(file.path)}'])}';
        if (windowsCommandLineLength([
              args.first,
              '@${p.absolute(file.path)}',
            ]) >=
            32767) {
          throw FlutterBuildError('Compiler response-file path is too long');
        }
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

  static Future<void> _pruneWindowsResponseFiles(String scratchPath) async {
    final cache = Directory(p.join(scratchPath, '.xcross-response'));
    if (!cache.existsSync()) return;
    final referenced = <String>{};
    for (final plan in Directory(scratchPath).listSync().whereType<File>()) {
      if (p.extension(plan.path) != '.yaml') continue;
      for (final line in await plan.readAsLines()) {
        const prefix = '    args: ';
        if (!line.startsWith('$prefix[')) continue;
        final Object? decoded;
        try {
          decoded = jsonDecode(line.substring(prefix.length));
        } on FormatException {
          continue;
        }
        if (decoded is! List) continue;
        for (final argument in decoded.whereType<String>()) {
          if (!argument.startsWith('@')) continue;
          final file = p.normalize(argument.substring(1));
          if (p.isWithin(cache.path, file)) referenced.add(file);
        }
      }
    }
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    for (final file in cache.listSync().whereType<File>()) {
      final name = p.basename(file.path);
      if (!RegExp(r'^[a-f0-9]{64}\.rsp$').hasMatch(name) ||
          referenced.contains(p.normalize(file.path)) ||
          !file.lastModifiedSync().isBefore(cutoff)) {
        continue;
      }
      await file.delete();
    }
  }

  /// Conservative CreateProcess length in UTF-16 units, including the NUL.
  static int windowsCommandLineLength(List<String> arguments) =>
      arguments.map(quoteWindowsArgument).join(' ').length + 1;

  static String quoteWindowsArgument(String argument) =>
      '"${argument.replaceAllMapped(RegExp(r'(\\*)"'), (match) => '${match[1]}${match[1]}\\"').replaceAllMapped(RegExp(r'\\+$'), (match) => '${match[0]}${match[0]}')}"';

  static String quoteGnuArgument(String argument) =>
      '"${argument.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  /// Foundation's directory copy mishandles extended drive paths as file URLs
  /// on Windows. Keep llbuild's node identities intact and normalize only the
  /// directory source passed by CopyCommand to FileManager in description.json.
  static String normalizeWindowsDirectoryCopyInputs(String description) {
    final decoded = jsonDecode(description);
    if (decoded is! Map<String, dynamic>) return description;
    final commands = decoded['copyCommands'];
    if (commands is! Map<String, dynamic>) return description;
    var changed = false;
    for (final command in commands.values) {
      if (command is! Map<String, dynamic>) continue;
      final inputs = command['inputs'];
      if (inputs is! List<dynamic>) continue;
      for (final input in inputs) {
        if (input is! Map<String, dynamic> || input['kind'] != 'directory') {
          continue;
        }
        final name = input['name'];
        if (name is String &&
            name.startsWith(r'\\?\') &&
            RegExp(r'^[a-zA-Z]:\\').hasMatch(name.substring(4)) &&
            _windowsCopyTreeFitsLegacyPaths(name.substring(4))) {
          input['name'] = name.substring(4);
          changed = true;
        }
      }
    }
    return changed
        ? const JsonEncoder.withIndent('  ').convert(decoded)
        : description;
  }

  /// Foundation's copy command cannot read some extended-length directory
  /// inputs on Windows. Present only those inputs through a short junction
  /// inside this build's scratch directory; vendor sources stay unchanged.
  static Future<String> stageWindowsDirectoryCopyInputs(
    String description,
    String scratchPath, {
    bool? windows,
  }) async {
    if (!(windows ?? Platform.isWindows)) return description;
    final decoded = jsonDecode(description);
    if (decoded is! Map<String, dynamic>) return description;
    final commands = decoded['copyCommands'];
    if (commands is! Map<String, dynamic>) return description;
    var changed = false;
    for (final command in commands.values) {
      if (command is! Map<String, dynamic>) continue;
      final inputs = command['inputs'];
      if (inputs is! List<dynamic>) continue;
      for (final input in inputs) {
        if (input is! Map<String, dynamic> || input['kind'] != 'directory') {
          continue;
        }
        final name = input['name'];
        if (name is! String ||
            !name.startsWith(r'\\?\') ||
            !RegExp(r'^[a-zA-Z]:\\').hasMatch(name.substring(4))) {
          continue;
        }
        final source = name.substring(4);
        if (_windowsCopyTreeFitsLegacyPaths(source)) continue;
        if (!Directory(name).existsSync()) continue;
        final digest = sha256.convert(utf8.encode(p.windows.normalize(source)));
        final alias = p.join(
          scratchPath,
          '.xcross-copy-inputs',
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
    }
    return changed
        ? const JsonEncoder.withIndent('  ').convert(decoded)
        : description;
  }

  static Future<void> _ensureWindowsDirectoryCopyAlias(
    String alias,
    String source,
  ) async {
    final target = p.windows.normalize(
      await Directory(source).resolveSymbolicLinks(),
    );
    final aliasDirectory = Directory(alias);
    if (FileSystemEntity.typeSync(alias, followLinks: false) ==
        FileSystemEntityType.notFound) {
      await aliasDirectory.parent.create(recursive: true);
      // PowerShell receives the paths as quoted literals, unlike cmd /c
      // mklink, which expands %NAME% and interprets & in user directory names.
      // New-Item treats brackets in the target as wildcard syntax.
      String literal(String path) => "'${path.replaceAll("'", "''")}'";
      final literalTarget = target.replaceAll('[', '`[').replaceAll(']', '`]');
      final result = await ProcessRunner.run(
        await ProcessRunner.locateTool('powershell.exe'),
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'New-Item -ItemType Junction -Path ${literal(alias)} -Target ${literal(literalTarget)} | Out-Null',
        ],
      );
      if (result.exitCode != 0 &&
          FileSystemEntity.typeSync(alias, followLinks: false) ==
              FileSystemEntityType.notFound) {
        throw FlutterBuildError(
          'Could not stage long SwiftPM directory copy: ${result.stderr}',
        );
      }
    }
    final mount = await ProcessRunner.run(
      await ProcessRunner.locateTool('fsutil.exe'),
      ['reparsepoint', 'query', alias],
    );
    if (mount.exitCode != 0 ||
        !isWindowsMountPointReparseOutput(mount.stdout) ||
        !p.windows.equals(
          await aliasDirectory.resolveSymbolicLinks(),
          target,
        )) {
      throw FlutterBuildError(
        'Refusing a changed SwiftPM directory copy alias: $alias',
      );
    }
  }

  static bool _windowsCopyTreeFitsLegacyPaths(String root) {
    if (root.length >= 260) return false;
    final directory = Directory(root);
    if (!directory.existsSync()) return true;
    return directory
        .listSync(recursive: true, followLinks: false)
        .every((entry) => entry.path.length < 260);
  }
}
