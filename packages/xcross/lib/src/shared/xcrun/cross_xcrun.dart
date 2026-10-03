import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';

final class CrossXcrunOperation implements XcrunOperation {
  const CrossXcrunOperation(this.loader, {required this.executable});
  final XcrunRuntimeLoader loader;
  final String executable;

  @override
  Future<int> run(List<String> arguments) async {
    final response = xcrunShimResponse(arguments, executable: executable);
    if (response != null) {
      stdout.writeln(response);
      return 0;
    }
    final services = await loader.loadXcrun(
      sdkName: _sdkBaseName(
        (_requestedSdk(_wrapperArguments(arguments)) ?? 'iphoneos')
            .toLowerCase(),
      ),
    );
    return runXcrun(
      arguments,
      runner: services.runner,
      repository: services.repository,
      toolchain: services.toolchain,
      normalizeExecutable: services.normalizeExecutable,
      target: services.target,
      executable: executable,
    );
  }
}

/// Version reported by `xcrun --version`, matching a recent Xcode's xcrun.
const xcrunCompatVersion = '72';

/// Tools that an installed compiler shim directory provides as `<tool>.exe`.
const _shimTools = {'clang', 'cc', 'ar', 'ld'};

/// The SDK path recorded in the `<xcrun>.sdk` sidecar next to a compiler shim.
String? _readShimSdk(String executable) {
  final sidecar = File('$executable.sdk');
  if (!sidecar.existsSync()) return null;
  final sdk = sidecar.readAsStringSync().trim();
  return sdk.isEmpty ? null : sdk;
}

/// Answers the `xcrun` probes that Flutter native-asset hooks run from a
/// sanitized environment.
String? xcrunShimResponse(
  List<String> arguments, {
  required String executable,
}) {
  // A version probe identifies xcrun itself only when no tool was selected.
  // It must also work before an SDK sidecar has been installed.
  if (arguments case ['--version'] || ['-version']) {
    return 'xcrun version $xcrunCompatVersion.';
  }
  final xcrunExecutable = executable;
  final shimSdk = _readShimSdk(xcrunExecutable);
  if (shimSdk == null) return null;

  final wrapperArguments = _wrapperArguments(arguments);
  _requireSdkSelection(wrapperArguments, shimSdk);

  if (wrapperArguments.contains('--show-sdk-path')) return shimSdk;
  if (wrapperArguments.contains('--show-sdk-version')) {
    return _sdkVersion(shimSdk);
  }
  if (wrapperArguments.contains('--show-sdk-platform-path')) {
    return _sdkPlatformPath(shimSdk);
  }
  return findShimTool(wrapperArguments, executable: xcrunExecutable);
}

/// Resolves a compiler shim without consulting user configuration.
///
/// Flutter invokes `xcrun --find` from a sanitized native-assets hook
/// environment. On Windows, PATH probing can reconstruct an existing
/// lowercase `clang.exe` as `clang.EXE` from the default PATHEXT value. That
/// spelling is rejected by native_toolchain_c's case-sensitive recognizer.
String? findShimTool(List<String> arguments, {required String executable}) {
  final xcrunExecutable = executable;
  final shimSdk = _readShimSdk(xcrunExecutable);
  if (shimSdk == null) return null;

  final wrapperArguments = _wrapperArguments(arguments);
  _requireSdkSelection(wrapperArguments, shimSdk);
  final find = wrapperArguments.indexOf('--find');
  if (find == -1 || find + 1 >= wrapperArguments.length) return null;

  final tool = wrapperArguments[find + 1];
  if (!_shimTools.contains(tool)) return null;

  final candidate = p.join(p.dirname(xcrunExecutable), '$tool.exe');
  return File(candidate).existsSync() ? candidate : null;
}

Future<int> runXcrun(
  List<String> arguments, {
  required ProcessRunner runner,
  required DarwinSdkRepository repository,
  required DarwinToolchainResolver toolchain,
  required String executable,
  required String Function(String) normalizeExecutable,
  required IosBuildPlatformInterface target,
  DarwinSdk? sdk,
  Future<String?> Function(String name)? findOnPath,
  Future<int> Function(String tool, List<String> arguments)? runTool,
}) async {
  // Build hooks (native_toolchain_c) probe `xcrun --version` before asking
  // for SDK paths, and parse a version number out of the output. Mirror the
  // real xcrun's format so that probe succeeds without an installed SDK.
  if (arguments case ['--version'] || ['-version']) {
    stdout.writeln('xcrun version $xcrunCompatVersion.');
    return 0;
  }

  sdk ??= repository.current();
  if (sdk == null) {
    stderr.writeln(
      'xcrun: no Darwin SDK installed; run `xcross sdk install` first',
    );
    return 1;
  }

  final wrapperArguments = _wrapperArguments(arguments);
  String? installedSdk;
  try {
    final shimSdk = _readShimSdk(executable);
    if (shimSdk != null) {
      _requireSdkSelection(wrapperArguments, shimSdk);
      installedSdk = shimSdk;
    } else {
      final requested = _requestedSdk(wrapperArguments);
      if (requested != null &&
          _sdkBaseName(requested.toLowerCase()) != target.sdkName) {
        throw FormatException('SDK $requested is not installed');
      }
      if (requested != null ||
          wrapperArguments.contains('--show-sdk-path') ||
          wrapperArguments.contains('--show-sdk-version') ||
          wrapperArguments.contains('--show-sdk-platform-path')) {
        installedSdk = repository.iosSdk(sdk, target: target);
        _requireSdkSelection(wrapperArguments, installedSdk);
      }
    }
    if (wrapperArguments.contains('--show-sdk-version')) {
      stdout.writeln(_sdkVersion(installedSdk!));
      return 0;
    }
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    return 1;
  }

  if (wrapperArguments.contains('--show-sdk-path')) {
    stdout.writeln(installedSdk);
    return 0;
  }
  if (wrapperArguments.contains('--show-sdk-platform-path')) {
    stdout.writeln(_sdkPlatformPath(installedSdk!));
    return 0;
  }

  final find = wrapperArguments.indexOf('--find');
  if (find >= 0) {
    if (find + 1 >= wrapperArguments.length) return 1;
    final tool = await _resolveTool(
      sdk,
      wrapperArguments[find + 1],
      runner: runner,
      repository: repository,
      sysroot: installedSdk,
      toolchain: toolchain,
      executable: executable,
      normalizeExecutable: normalizeExecutable,
      target: target,
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
    runner: runner,
    repository: repository,
    sysroot: installedSdk,
    toolchain: toolchain,
    executable: executable,
    normalizeExecutable: normalizeExecutable,
    target: target,
    findOnPath: findOnPath,
  );
  if (tool == null) {
    stderr.writeln('xcrun: unknown tool ${arguments[toolIndex]}');
    return 1;
  }
  final toolArguments = arguments.sublist(toolIndex + 1);
  if (runTool != null) return runTool(tool, toolArguments);
  return runResolvedTool(tool, toolArguments, runner: runner);
}

/// Streams a resolved tool directly and preserves its exact exit status.
Future<int> runResolvedTool(
  String tool,
  List<String> arguments, {
  required ProcessRunner runner,
  Future<Process> Function(String tool, List<String> arguments)? start,
}) async {
  final child =
      await (start ??
          ((tool, args) => runner.start(
            tool,
            args,
            mode: ProcessStartMode.inheritStdio,
          )))(tool, arguments);
  return child.exitCode;
}

int _toolIndex(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--sdk') {
      index++;
      continue;
    }
    if (arguments[index].startsWith('--sdk=')) continue;
    if (arguments[index] == '--find') return -1;
    if (!arguments[index].startsWith('-')) return index;
  }
  return -1;
}

/// Wrapper flags end at the selected tool; everything after it belongs to the
/// child, even when an argument has the same spelling as an xcrun option.
List<String> _wrapperArguments(List<String> arguments) {
  final toolIndex = _toolIndex(arguments);
  return arguments.sublist(0, toolIndex < 0 ? arguments.length : toolIndex);
}

void _requireSdkSelection(List<String> arguments, String installedSdk) {
  final installedName = _sdkName(installedSdk);
  final target = _sdkBaseName(installedName);
  final requested = _requestedSdk(arguments);
  if (requested == null) return;
  final name = requested.toLowerCase();
  if (name == target || name == installedName) return;
  if (_sdkBaseName(name) == target &&
      name == '$target${_sdkVersion(installedSdk)}') {
    return;
  }
  throw FormatException('SDK $requested is not installed');
}

String _sdkBaseName(String name) {
  final match = RegExp(
    r'^(iphoneos|iphonesimulator)(?:[0-9]+(?:\.[0-9]+)*)?$',
  ).firstMatch(name);
  if (match == null) throw FormatException('SDK $name is not installed');
  return match.group(1)!;
}

String _sdkName(String sdkPath) =>
    (sdkPath.contains(r'\')
            ? p.windows.basenameWithoutExtension(sdkPath)
            : p.basenameWithoutExtension(sdkPath))
        .toLowerCase();

String _sdkVersion(String sdkPath) {
  final name = _sdkName(sdkPath);
  final target = _sdkBaseName(name);
  final version = name.substring(target.length);
  if (version.isNotEmpty) return version;
  final settings = File(p.join(sdkPath, 'SDKSettings.json'));
  if (settings.existsSync()) {
    final data = jsonDecode(settings.readAsStringSync());
    if (data is Map<String, dynamic> && data['Version'] is String) {
      final version = data['Version'] as String;
      if (RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(version)) return version;
    }
  }
  throw FormatException('SDK version is unavailable for $sdkPath');
}

/// The last `--sdk <name>` or `--sdk=<name>` value, as real xcrun honors.
String? _requestedSdk(List<String> arguments) {
  String? requested;
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--sdk') {
      if (index + 1 >= arguments.length) {
        throw const FormatException('missing SDK name after --sdk');
      }
      requested = arguments[++index];
    } else if (argument.startsWith('--sdk=')) {
      requested = argument.substring('--sdk='.length);
    }
  }
  return requested;
}

Future<String?> _resolveTool(
  DarwinSdk sdk,
  String name, {
  required ProcessRunner runner,
  required DarwinSdkRepository repository,
  required String? sysroot,
  required DarwinToolchainResolver toolchain,
  required String executable,
  required String Function(String) normalizeExecutable,
  required IosBuildPlatformInterface target,
  Future<String?> Function(String name)? findOnPath,
}) async {
  final pathTool =
      await (findOnPath ??
          ((name) => runner.which(name, useConfiguration: false)))(name);
  if (pathTool != null &&
      runner.host.paths.pathKey(pathTool) !=
          runner.host.paths.pathKey(executable)) {
    // On Windows, PATH lookup can append PATHEXT's `.EXE` spelling even if
    // the actual shim is `clang.exe`. native_toolchain_c recognizes configured
    // compilers by a case-sensitive `endsWith('clang.exe')`, so return the
    // lowercase extension it expects (Windows paths are case-insensitive).
    return normalizeExecutable(pathTool);
  }

  switch (name) {
    case 'clang':
    case 'clang++':
      return toolchain.resolveDarwinClang(
        sysroot ?? repository.iosSdk(sdk, target: target),
        name: name,
      );
    case 'ld':
      return toolchain.resolveLd64Lld();
    case 'ar':
      final clang = await toolchain.resolveDarwinClang(
        sysroot ?? repository.iosSdk(sdk, target: target),
      );
      final sibling = p.join(
        p.dirname(clang),
        runner.host.paths.executableName('llvm-ar'),
      );
      if (File(sibling).existsSync()) return sibling;
      return toolchain.locateLlvmTool(
        runner.host.paths.executableName('llvm-ar'),
      );
    case 'lipo':
      return toolchain.locateLlvmTool(
        runner.host.paths.executableName('llvm-lipo'),
      );
    case 'otool':
      return await toolchain.locateLlvmTool(
            runner.host.paths.executableName('llvm-otool'),
          ) ??
          toolchain.locateLlvmTool(
            runner.host.paths.executableName('llvm-objdump'),
          );
    case 'install_name_tool':
      return toolchain.locateLlvmTool(
        runner.host.paths.executableName('llvm-install-name-tool'),
      );
    case 'codesign':
      return null;
    default:
      return toolchain.locateLlvmTool(runner.host.paths.executableName(name));
  }
}

String _sdkPlatformPath(String sdkPath) {
  final context = sdkPath.contains(r'\') ? p.windows : p.context;
  return context.dirname(context.dirname(context.dirname(sdkPath)));
}
