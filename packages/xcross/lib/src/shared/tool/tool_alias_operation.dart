import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/tool/mach_o_slices.dart';

typedef ToolAliasRun =
    Future<int> Function(String executable, List<String> arguments);

final class ToolAliasOperation {
  const ToolAliasOperation(this.runner);
  final ProcessRunner runner;

  Future<int?> run(
    List<String> arguments, {
    required String executablePath,
    Map<String, String>? environment,
    ToolAliasRun? run,
  }) async {
    final path = executablePath;
    final name = runner.host.paths.context
        .basenameWithoutExtension(path)
        .toLowerCase();
    if (name == 'plutil') return runPlutilAlias(arguments);
    final variable = _toolAliasVariables[name];
    if (variable == null) return null;

    final mapping = runner.host.fileSystem.file('$path.path');
    final target = mapping.existsSync()
        ? mapping.readAsStringSync().trim()
        : (environment ?? runner.effectiveEnvironment)[variable];
    if (target == null || target.isEmpty) {
      runner.log.output.stderr('error: missing trusted tool mapping $variable');
      return 1;
    }
    final invoke =
        run ??
        ((executable, arguments) =>
            _runToolAlias(runner, executable, arguments));
    // dsymutil (unlike ld/strip/libtool/clang) is not on every LLVM
    // distribution: the swift.org Windows LLVM installer's LLVM/bin has
    // ld64.lld.exe and llvm-strip.exe but no dsymutil.exe (confirmed against
    // a real CI run — Process.start fails with "The system cannot find the
    // file specified"). Kotlin/Native's MacOSBasedLinker calls dsymutil
    // unconditionally after every framework link and fails the whole compile
    // on any nonzero exit, but nothing downstream in xcross reads the
    // resulting .dSYM bundle, so a missing dsymutil should degrade to a
    // silent no-op instead of a build failure.
    if (name == 'dsymutil' &&
        !runner.host.fileSystem.file(target).existsSync()) {
      return 0;
    }
    if (name == 'libtool' &&
        !runner.host.fileSystem.file(target).existsSync()) {
      final archiver = _llvmArchiverFor(target);
      if (archiver != null) {
        final converted = libtoolAsArArguments(arguments);
        if (converted != null) return invoke(archiver, converted);
      }
    }
    final prefix = runner.host.fileSystem.file('$path.args');
    final forwarded =
        prefix.existsSync() && _isAppleCompilerInvocation(arguments)
        ? [
            ...(jsonDecode(prefix.readAsStringSync()) as List).cast<String>(),
            ...arguments,
          ]
        : arguments;
    return invoke(target, forwarded);
  }

  /// `llvm-ar` next to a missing `llvm-libtool-darwin`: the official LLVM
  /// Windows installer ships the former but not the latter.
  String? _llvmArchiverFor(String libtool) {
    final paths = runner.host.paths.context;
    final candidate = paths.join(
      paths.dirname(libtool),
      runner.host.paths.executableName('llvm-ar'),
    );
    return runner.host.fileSystem.file(candidate).existsSync()
        ? candidate
        : null;
  }

  /// Rewrites the `libtool -static` invocation Kotlin/Native issues as an
  /// equivalent `llvm-ar` one, or null when it is not a static archive.
  List<String>? libtoolAsArArguments(List<String> arguments) {
    String? output;
    final inputs = <String>[];
    var isStatic = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      switch (argument) {
        case '-static':
          isStatic = true;
        case '-D' || '-no_warning_for_no_symbols' || '-s' || '-a' || '-c':
          break;
        case '-o' when index + 1 < arguments.length:
          output = arguments[++index];
        case '-arch_only' when index + 1 < arguments.length:
          index++;
        case '-filelist' when index + 1 < arguments.length:
          final list = runner.host.fileSystem.file(
            arguments[++index].split(',').first,
          );
          if (!list.existsSync()) return null;
          inputs.addAll(
            list
                .readAsLinesSync()
                .map((line) => line.trim())
                .where((line) => line.isNotEmpty),
          );
        default:
          if (argument.startsWith('-')) return null;
          inputs.add(argument);
      }
    }
    if (!isStatic || output == null) return null;
    final existing = runner.host.fileSystem.file(output);
    if (existing.existsSync()) existing.deleteSync();
    final thinDir = runner.host.fileSystem.directory('$output.slices');
    return [
      'qLsD',
      '--format=darwin',
      output,
      for (final (index, input) in inputs.indexed)
        _arm64Slice(input, thinDir, index) ?? input,
    ];
  }

  String? _arm64Slice(String path, Directory dir, int index) {
    final file = runner.host.fileSystem.file(path);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    final range = arm64SliceRange(bytes);
    if (range == null) return null;
    dir.createSync(recursive: true);
    final slice = runner.host.paths.context.join(
      dir.path,
      '$index-${runner.host.paths.context.basename(path)}',
    );
    runner.host.fileSystem
        .file(slice)
        .writeAsBytesSync(bytes.sublist(range.$1, range.$2));
    return slice;
  }

  bool _isAppleCompilerInvocation(List<String> arguments) {
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '-arch' ||
          argument.startsWith('-arch=') ||
          argument.startsWith('-miphoneos-version-min=') ||
          argument.startsWith('-mios-simulator-version-min=')) {
        return true;
      }
      if ((argument == '-target' || argument == '--target') &&
          index + 1 < arguments.length &&
          arguments[index + 1].contains('-apple-')) {
        return true;
      }
      if ((argument.startsWith('-target=') ||
              argument.startsWith('--target=')) &&
          argument.contains('-apple-')) {
        return true;
      }
    }
    return false;
  }

  Future<int> runPlutilAlias(List<String> arguments) async {
    if (arguments case [
      '-replace',
      'MinimumOSVersion',
      '-string',
      final String version,
      final String path,
    ]) {
      final file = runner.host.fileSystem.file(path);
      if (!file.existsSync()) return 1;
      final original = await file.readAsString();
      final pattern = RegExp(
        r'<key>MinimumOSVersion</key>\s*<string>[^<]*</string>',
      );
      if (!pattern.hasMatch(original)) return 1;
      await file.writeAsString(
        original.replaceFirst(
          pattern,
          '<key>MinimumOSVersion</key>\n\t<string>$version</string>',
        ),
      );
      return 0;
    }
    return 1;
  }

  Future<int> _runToolAlias(
    ProcessRunner runner,
    String executable,
    List<String> arguments,
  ) async {
    final Process process;
    try {
      process = await runner.start(
        executable,
        arguments,
        mode: ProcessStartMode.inheritStdio,
      );
    } on CliError catch (error) {
      runner.log.output.stderr('error: ${error.message}');
      return 1;
    }
    return process.exitCode;
  }

  static const _toolAliasVariables = {
    'ld': 'XCROSS_APPLE_TOOL_LD',
    'strip': 'XCROSS_APPLE_TOOL_STRIP',
    'dsymutil': 'XCROSS_APPLE_TOOL_DSYMUTIL',
    'libtool': 'XCROSS_APPLE_TOOL_LIBTOOL',
    'clang': 'XCROSS_APPLE_TOOL_CLANG',
    'clang++': 'XCROSS_APPLE_TOOL_CLANGXX',
    'cc': 'XCROSS_APPLE_TOOL_CC',
    'ar': 'XCROSS_APPLE_TOOL_AR',
  };
}
