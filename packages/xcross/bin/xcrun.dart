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
    final shimResponse = xcrunShimResponse(arguments);
    if (shimResponse != null) {
      stdout.writeln(shimResponse);
      return;
    }
    await XcrossRuntimeConfig.initialize();
    exitCode = await runXcrun(arguments);
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    exitCode = 1;
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
String? xcrunShimResponse(List<String> arguments, {String? executable}) {
  // A version probe identifies xcrun itself only when no tool was selected.
  // It must also work before an SDK sidecar has been installed.
  if (arguments case ['--version'] || ['-version']) {
    return 'xcrun version $xcrunCompatVersion.';
  }
  final xcrunExecutable = executable ?? Platform.resolvedExecutable;
  final shimSdk = _readShimSdk(xcrunExecutable);
  if (shimSdk == null) return null;

  final wrapperArguments = _wrapperArguments(arguments);
  _requireIPhoneOsSdk(wrapperArguments, shimSdk);

  if (wrapperArguments.contains('--show-sdk-path')) return shimSdk;
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
String? findShimTool(List<String> arguments, {String? executable}) {
  final xcrunExecutable = executable ?? Platform.resolvedExecutable;
  if (_readShimSdk(xcrunExecutable) == null) return null;

  final wrapperArguments = _wrapperArguments(arguments);
  final find = wrapperArguments.indexOf('--find');
  if (find == -1 || find + 1 >= wrapperArguments.length) return null;

  final tool = wrapperArguments[find + 1];
  if (!_shimTools.contains(tool)) return null;

  final candidate = p.join(p.dirname(xcrunExecutable), '$tool.exe');
  return File(candidate).existsSync() ? candidate : null;
}

Future<int> runXcrun(
  List<String> arguments, {
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

  sdk ??= DarwinSdk.current();
  if (sdk == null) {
    stderr.writeln(
      'xcrun: no Darwin SDK installed; run `xcross sdk install` first',
    );
    return 1;
  }

  final wrapperArguments = _wrapperArguments(arguments);
  try {
    _requireInstalledSdk(wrapperArguments, sdk);
  } on FormatException catch (error) {
    stderr.writeln('xcrun: $error');
    return 1;
  }

  if (wrapperArguments.contains('--show-sdk-path')) {
    stdout.writeln(sdk.iPhoneOSSdk());
    return 0;
  }
  if (wrapperArguments.contains('--show-sdk-platform-path')) {
    stdout.writeln(_sdkPlatformPath(sdk.iPhoneOSSdk()));
    return 0;
  }

  final find = wrapperArguments.indexOf('--find');
  if (find >= 0) {
    if (find + 1 >= wrapperArguments.length) return 1;
    final tool = await _resolveTool(
      sdk,
      wrapperArguments[find + 1],
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
  final toolArguments = arguments.sublist(toolIndex + 1);
  if (runTool != null) return runTool(tool, toolArguments);
  return runResolvedTool(tool, toolArguments);
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

/// Rejects an `--sdk` selection other than the installed iPhoneOS SDK.
///
/// Non-iPhoneOS names are rejected before [DarwinSdk.iPhoneOSSdk] is
/// consulted, so they fail with a [FormatException] even when no iPhoneOS SDK
/// can be located.
void _requireInstalledSdk(List<String> wrapperArguments, DarwinSdk sdk) {
  final requested = _requestedSdk(wrapperArguments);
  if (requested == null) return;
  if (!requested.toLowerCase().startsWith('iphoneos')) {
    throw FormatException('SDK $requested is not installed');
  }
  _requireIPhoneOsSdk(wrapperArguments, sdk.iPhoneOSSdk());
}

/// Accepts `--sdk iphoneos` or the exact name of [installedSdk].
void _requireIPhoneOsSdk(List<String> arguments, String installedSdk) {
  final requested = _requestedSdk(arguments);
  if (requested == null) return;
  final name = requested.toLowerCase();
  final installedName = p.basenameWithoutExtension(installedSdk).toLowerCase();
  if (name != 'iphoneos' && name != installedName) {
    throw FormatException('SDK $requested is not installed');
  }
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

Future<String?> _findOnPath(String name) =>
    ProcessRunner.which(name, useConfiguration: false);

Future<String?> _resolveTool(
  DarwinSdk sdk,
  String name, {
  Future<String?> Function(String name)? findOnPath,
}) async {
  final pathTool = await (findOnPath ?? _findOnPath)(name);
  if (pathTool != null && !_isCurrentExecutable(pathTool)) {
    // On Windows, PATH lookup can append PATHEXT's `.EXE` spelling even if
    // the actual shim is `clang.exe`. native_toolchain_c recognizes configured
    // compilers by a case-sensitive `endsWith('clang.exe')`, so return the
    // lowercase extension it expects (Windows paths are case-insensitive).
    return normalizeWindowsExecutableExtension(pathTool);
  }

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

String normalizeWindowsExecutableExtension(String path, {bool? windows}) {
  if (!(windows ?? Platform.isWindows)) return path;
  if (p.windows.extension(path).toLowerCase() != '.exe') return path;
  return '${p.windows.withoutExtension(path)}.exe';
}

bool _isCurrentExecutable(String path) =>
    p.canonicalize(path) == p.canonicalize(Platform.resolvedExecutable);

/// The iPhoneOS SDK lives at `<platform>/Developer/SDKs/<sdk>.sdk`.
String _sdkPlatformPath(String sdkPath) =>
    p.dirname(p.dirname(p.dirname(sdkPath)));
