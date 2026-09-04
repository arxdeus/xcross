import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/xcross.dart';

Future<void> main(List<String> arguments) async {
  if (Platform.isMacOS) {
    stderr.writeln('xcross xcrun is only intended for Windows and Linux.');
    exitCode = 1;
    return;
  }

  try {
    await XcrossRuntimeConfig.initialize();
    exitCode = await runXcrun(arguments);
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    exitCode = 1;
  }
}

Future<int> runXcrun(
  List<String> arguments, {
  DarwinSdk? sdk,
  Future<String?> Function(String name)? findOnPath,
}) async {
  sdk ??= DarwinSdk.current();
  if (sdk == null) {
    stderr.writeln(
      'xcrun: no Darwin SDK installed; run `xcross sdk install` first',
    );
    return 1;
  }

  if (arguments.contains('--show-sdk-path')) {
    stdout.writeln(sdk.iPhoneOSSdk());
    return 0;
  }

  final find = arguments.indexOf('--find');
  if (find >= 0) {
    if (find + 1 >= arguments.length) return 1;
    final tool = await _resolveTool(
      sdk,
      arguments[find + 1],
      findOnPath: findOnPath,
    );
    if (tool == null) return 1;
    stdout.writeln(tool);
    return 0;
  }

  final toolIndex = _toolIndex(arguments);
  if (toolIndex == -1) return 1;
  final tool = await _resolveTool(
    sdk,
    arguments[toolIndex],
    findOnPath: findOnPath,
  );
  if (tool == null) {
    stderr.writeln('xcrun: unknown tool ${arguments[toolIndex]}');
    return 1;
  }
  return runResolvedTool(tool, arguments.sublist(toolIndex + 1));
}

/// Streams a resolved tool directly and preserves its exact exit status.
Future<int> runResolvedTool(
  String tool,
  List<String> arguments, {
  Future<Process> Function(String tool, List<String> arguments)? start,
}) async {
  final child = await (start ?? _startInherited)(tool, arguments);
  return child.exitCode;
}

Future<Process> _startInherited(String tool, List<String> arguments) =>
    ProcessRunner.start(tool, arguments, mode: ProcessStartMode.inheritStdio);

int _toolIndex(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--sdk') {
      index++;
      continue;
    }
    if (!arguments[index].startsWith('-')) return index;
  }
  return -1;
}

Future<String?> _findOnPath(String name) =>
    ProcessRunner.which(name, useConfiguration: false);

Future<String?> _resolveTool(
  DarwinSdk sdk,
  String name, {
  Future<String?> Function(String name)? findOnPath,
}) async {
  final pathTool = await (findOnPath ?? _findOnPath)(name);
  if (pathTool != null && !_isCurrentExecutable(pathTool)) return pathTool;

  switch (name) {
    case 'clang':
    case 'clang++':
      return DarwinSdk.resolveDarwinClang(sdk, name: name);
    case 'ld':
      return DarwinSdk.resolveLd64Lld(sdk);
    case 'ar':
      final clang = await DarwinSdk.resolveDarwinClang(sdk);
      final sibling = p.join(
        p.dirname(clang),
        'llvm-ar${Platform.isWindows ? '.exe' : ''}',
      );
      if (File(sibling).existsSync()) return sibling;
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows ? 'llvm-ar.exe' : 'llvm-ar',
      );
    case 'lipo':
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows ? 'llvm-lipo.exe' : 'llvm-lipo',
      );
    case 'otool':
      return await DarwinSdk.locateLlvmTool(
            Platform.isWindows ? 'llvm-otool.exe' : 'llvm-otool',
          ) ??
          DarwinSdk.locateLlvmTool(
            Platform.isWindows ? 'llvm-objdump.exe' : 'llvm-objdump',
          );
    case 'install_name_tool':
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows
            ? 'llvm-install-name-tool.exe'
            : 'llvm-install-name-tool',
      );
    case 'codesign':
      return null;
    default:
      return DarwinSdk.locateLlvmTool(Platform.isWindows ? '$name.exe' : name);
  }
}

bool _isCurrentExecutable(String path) =>
    p.canonicalize(path) == p.canonicalize(Platform.resolvedExecutable);
