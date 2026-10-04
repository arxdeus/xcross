import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit_shared.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/xcrun/xcrun_operation.dart';

final class CrossXcrunOperation implements XcrunOperation {
  const CrossXcrunOperation(
    this.loader, {
    required this.host,
    required this.executable,
    required this.output,
    required this.errors,
  });
  final XcrunRuntimeLoader loader;
  final PlatformHostInterface host;
  final String executable;
  final IOSink output;
  final IOSink errors;

  @override
  Future<int> run(List<String> arguments) async {
    final response = CrossXcrunProbe(
      host,
    ).response(arguments, executable: executable);
    if (response != null) {
      output.writeln(response);
      return 0;
    }
    final services = await loader.loadXcrun(
      sdkName: _sdkBaseName(
        (_requestedSdk(_wrapperArguments(arguments)) ?? 'iphoneos')
            .toLowerCase(),
      ),
    );
    return XcrunSdkCommand(
      runner: services.runner,
      output: output,
      errors: errors,
      repository: services.repository,
      toolchain: services.toolchain,
      normalizeExecutable: services.normalizeExecutable,
      target: services.target,
      executable: executable,
    ).run(arguments);
  }
}

/// Version reported by `xcrun --version`, matching a recent Xcode's xcrun.
const xcrunCompatVersion = '72';

/// Tools that an installed compiler shim directory provides as `<tool>.exe`.
const _shimTools = {'clang', 'cc', 'ar', 'ld'};

/// The SDK path recorded in the `<xcrun>.sdk` sidecar next to a compiler shim.
final class CrossXcrunProbe {
  const CrossXcrunProbe(this.host);

  final PlatformHostInterface host;

  String? _readShimSdk(String executable) {
    final sidecar = host.fileSystem.file('$executable.sdk');
    if (!sidecar.existsSync()) return null;
    final sdk = sidecar.readAsStringSync().trim();
    return sdk.isEmpty ? null : sdk;
  }

  /// Answers the `xcrun` probes that Flutter native-asset hooks run from a
  /// sanitized environment.
  String? response(List<String> arguments, {required String executable}) {
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
    return findTool(wrapperArguments, executable: xcrunExecutable);
  }

  /// Resolves a compiler shim without consulting user configuration.
  ///
  /// Flutter invokes `xcrun --find` from a sanitized native-assets hook
  /// environment. On Windows, PATH probing can reconstruct an existing
  /// lowercase `clang.exe` as `clang.EXE` from the default PATHEXT value. That
  /// spelling is rejected by native_toolchain_c's case-sensitive recognizer.
  String? findTool(List<String> arguments, {required String executable}) {
    final xcrunExecutable = executable;
    final shimSdk = _readShimSdk(xcrunExecutable);
    if (shimSdk == null) return null;

    final wrapperArguments = _wrapperArguments(arguments);
    _requireSdkSelection(wrapperArguments, shimSdk);
    final find = wrapperArguments.indexOf('--find');
    if (find == -1 || find + 1 >= wrapperArguments.length) return null;

    final tool = wrapperArguments[find + 1];
    if (!_shimTools.contains(tool)) return null;

    final candidate = host.paths.context.join(
      host.paths.context.dirname(xcrunExecutable),
      '$tool.exe',
    );
    return host.fileSystem.file(candidate).existsSync() ? candidate : null;
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

  String _sdkName(String sdkPath) =>
      (sdkPath.contains(r'\')
              ? p.windows.basenameWithoutExtension(sdkPath)
              : host.paths.context.basenameWithoutExtension(sdkPath))
          .toLowerCase();

  String _sdkVersion(String sdkPath) {
    final name = _sdkName(sdkPath);
    final target = _sdkBaseName(name);
    final version = name.substring(target.length);
    if (version.isNotEmpty) return version;
    final settings = host.fileSystem.file(
      host.paths.context.join(sdkPath, 'SDKSettings.json'),
    );
    if (settings.existsSync()) {
      final data = jsonDecode(settings.readAsStringSync());
      if (data is Map<String, dynamic> && data['Version'] is String) {
        final version = data['Version'] as String;
        if (RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(version)) return version;
      }
    }
    throw FormatException('SDK version is unavailable for $sdkPath');
  }

  String _sdkPlatformPath(String sdkPath) {
    final paths = sdkPath.contains(r'\') ? p.windows : host.paths.context;
    return paths.dirname(paths.dirname(paths.dirname(sdkPath)));
  }
}

final class XcrunSdkCommand {
  const XcrunSdkCommand({
    required this.runner,
    required this.output,
    required this.errors,
    required this.repository,
    required this.toolchain,
    required this.executable,
    required this.normalizeExecutable,
    required this.target,
  });

  final ProcessRunner runner;
  final IOSink output;
  final IOSink errors;
  final DarwinSdkRepository repository;
  final DarwinToolchainResolver toolchain;
  final String executable;
  final String Function(String) normalizeExecutable;
  final IosBuildPlatformInterface target;

  Future<int> run(List<String> arguments, {DarwinSdk? sdk}) async {
    final probe = CrossXcrunProbe(runner.host);
    // Build hooks (native_toolchain_c) probe `xcrun --version` before asking
    // for SDK paths, and parse a version number out of the output. Mirror the
    // real xcrun's format so that probe succeeds without an installed SDK.
    if (arguments case ['--version'] || ['-version']) {
      output.writeln('xcrun version $xcrunCompatVersion.');
      return 0;
    }

    sdk ??= repository.current();
    if (sdk == null) {
      errors.writeln(
        'xcrun: no Darwin SDK installed; run `xcross sdk install` first',
      );
      return 1;
    }

    final wrapperArguments = _wrapperArguments(arguments);
    String? installedSdk;
    try {
      final shimSdk = probe._readShimSdk(executable);
      if (shimSdk != null) {
        probe._requireSdkSelection(wrapperArguments, shimSdk);
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
          probe._requireSdkSelection(wrapperArguments, installedSdk);
        }
      }
      if (wrapperArguments.contains('--show-sdk-version')) {
        output.writeln(probe._sdkVersion(installedSdk!));
        return 0;
      }
    } on Object catch (error) {
      errors.writeln('xcrun: $error');
      return 1;
    }

    if (wrapperArguments.contains('--show-sdk-path')) {
      output.writeln(installedSdk);
      return 0;
    }
    if (wrapperArguments.contains('--show-sdk-platform-path')) {
      output.writeln(probe._sdkPlatformPath(installedSdk!));
      return 0;
    }

    final find = wrapperArguments.indexOf('--find');
    if (find >= 0) {
      if (find + 1 >= wrapperArguments.length) return 1;
      final tool = await _resolveTool(
        sdk,
        wrapperArguments[find + 1],
        sysroot: installedSdk,
      );
      if (tool == null) return 1;
      output.writeln(tool);
      return 0;
    }

    final toolIndex = _toolIndex(arguments);
    if (toolIndex == -1) return 1;
    final tool = await _resolveTool(
      sdk,
      arguments[toolIndex],
      sysroot: installedSdk,
    );
    if (tool == null) {
      errors.writeln('xcrun: unknown tool ${arguments[toolIndex]}');
      return 1;
    }
    final toolArguments = arguments.sublist(toolIndex + 1);
    return runResolvedTool(tool, toolArguments);
  }

  Future<String?> _resolveTool(
    DarwinSdk sdk,
    String name, {
    required String? sysroot,
  }) async {
    final pathTool = await runner.which(name, useConfiguration: false);
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
        final sibling = runner.host.paths.context.join(
          runner.host.paths.context.dirname(clang),
          runner.host.paths.executableName('llvm-ar'),
        );
        if (runner.host.fileSystem.file(sibling).existsSync()) return sibling;
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

  /// Streams a resolved tool directly and preserves its exact exit status.
  Future<int> runResolvedTool(String tool, List<String> arguments) async {
    final child = await runner.start(tool, arguments);
    final outputDone = output.addStream(child.stdout);
    final errorsDone = errors.addStream(child.stderr);
    final input = runner.sharedStdin.listen(
      child.stdin.add,
      onDone: child.stdin.close,
    );
    try {
      final code = await child.exitCode;
      await Future.wait([outputDone, errorsDone]);
      return code;
    } finally {
      await input.cancel();
    }
  }
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

String _sdkBaseName(String name) {
  final match = RegExp(
    r'^(iphoneos|iphonesimulator)(?:[0-9]+(?:\.[0-9]+)*)?$',
  ).firstMatch(name);
  if (match == null) throw FormatException('SDK $name is not installed');
  return match.group(1)!;
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
