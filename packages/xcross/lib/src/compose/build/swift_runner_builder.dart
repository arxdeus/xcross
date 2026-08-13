import 'dart:io';
import 'package:cli_kit/cli_kit.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/compose/build/mach_o_validator.dart';
import 'package:xcross/src/compose/build/process_invocation.dart';
import 'package:xcross/src/compose/project/kmp_project.dart';
import 'package:xcross/src/compose/toolchain/compose_toolchain.dart';
import 'package:xcross/src/errors.dart';

typedef SwiftRunnerRunChecked =
    Future<void> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });

const _iosTargetTriple = 'arm64-apple-ios15.0';
const _iosMinimumVersion = '15.0';

final class SwiftRunnerBuilder {
  SwiftRunnerBuilder() : _runChecked = _defaultRunChecked;

  const SwiftRunnerBuilder.withSeams({
    required SwiftRunnerRunChecked runChecked,
  }) : _runChecked = runChecked;

  final SwiftRunnerRunChecked _runChecked;

  Future<String> build({
    required KmpProject project,
    required String frameworkPath,
    required ComposeToolchain toolchain,
  }) async {
    _validateFramework(project, frameworkPath);
    if (project.swiftSources.isEmpty) {
      throw XcrossError('No Swift sources detected for ${project.appName}.');
    }
    for (final source in project.swiftSources) {
      if (!File(source).existsSync()) {
        throw XcrossError('Swift source not found: $source');
      }
    }
    final iphoneSdk = _iphoneSdk(toolchain);
    final buildDir = p.join(project.root, 'build', 'xcross-compose');
    await Directory(buildDir).create(recursive: true);
    final runnerPath = p.join(buildDir, 'Runner');
    final resourceDir = p.join(
      toolchain.darwinSdkBundle,
      'Developer',
      'Toolchains',
      'XcodeDefault.xctoolchain',
      'usr',
      'lib',
      'swift',
    );
    final moduleCache = p.join(buildDir, 'swift-module-cache');
    await Directory(moduleCache).create(recursive: true);
    final clangBuiltins = _clangBuiltins(resourceDir);

    final swiftc = ProcessInvocation.forHost(toolchain.host, toolchain.swiftc, [
      '-sdk',
      iphoneSdk,
      '-target',
      _iosTargetTriple,
      '-resource-dir',
      resourceDir,
      '-F',
      p.dirname(frameworkPath),
      '-framework',
      project.baseName,
      '-parse-as-library',
      '-module-cache-path',
      moduleCache,
      '-use-ld=${toolchain.ld64Lld}',
      '-Xfrontend',
      '-enable-cross-import-overlays',
      '-Xfrontend',
      '-disable-modules-validate-system-headers',
      '-Xcc',
      '-isysroot',
      '-Xcc',
      iphoneSdk,
      if (clangBuiltins != null) ...['-Xcc', '-isystem', '-Xcc', clangBuiltins],
      // swiftc hands the final link off to whatever clang is on the driving
      // host, asking it to invoke ld64.lld. On macOS that clang is Apple's
      // own and already knows how to synthesize "-arch"/"-platform_version"
      // for a Darwin target from -target alone. The Ubuntu-packaged clang
      // CI installs has no such Darwin-target-inference logic (it isn't an
      // Apple clang), so it passes neither flag through and ld64.lld fails
      // with "must specify -platform_version" / "missing or unsupported
      // -arch arm64". ObjcRunnerBuilder never hits this because it invokes
      // ld64.lld directly with both flags explicit; do the same for the
      // Swift link by forcing them through as literal linker arguments,
      // which works identically on every host (confirmed locally: the
      // macOS-clang-driven link produces byte-identical linker invocation
      // whether or not these are passed explicitly, so this is safe there
      // too).
      '-Xlinker',
      '-arch',
      '-Xlinker',
      'arm64',
      '-Xlinker',
      '-platform_version',
      '-Xlinker',
      'ios',
      '-Xlinker',
      _iosMinimumVersion,
      '-Xlinker',
      _sdkVersion(iphoneSdk) ?? '26.5',
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/Frameworks',
      ...project.swiftSources,
      '-o',
      runnerPath,
    ]);
    await _runChecked(
      swiftc.executable,
      swiftc.arguments,
      workingDirectory: project.root,
    );
    MachOValidator.validate64BitExecutable(runnerPath);
    if (!Platform.isWindows) ProcessRunner.makeExecutable(runnerPath);
    return runnerPath;
  }

  static Future<void> _defaultRunChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) => ProcessRunner.runChecked(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    label: p.basename(executable),
  );
}

String? _clangBuiltins(String resourceDir) {
  final candidate = p.join(resourceDir, 'clang', 'include');
  if (File(p.join(candidate, 'stdarg.h')).existsSync()) return candidate;
  return null;
}

String _iphoneSdk(ComposeToolchain toolchain) {
  // See the matching comment in objc_runner_builder.dart: darwinSdkPath is
  // already the resolved "iPhoneOS(.\d+)?.sdk" leaf.
  if (Directory(toolchain.darwinSdkPath).existsSync()) {
    return toolchain.darwinSdkPath;
  }
  throw XcrossError('iPhoneOS SDK not found at ${toolchain.darwinSdkPath}');
}

/// The SDK version suffix off an `iPhoneOS<version>.sdk` leaf name, or null
/// for a bare `iPhoneOS.sdk` with no version in its name. Duplicated from
/// objc_runner_builder.dart's identical helper rather than shared, to keep
/// each runner builder file self-contained.
String? _sdkVersion(String sdkPath) {
  final name = p.basenameWithoutExtension(sdkPath);
  if (!name.startsWith('iPhoneOS')) return null;
  final version = name.substring('iPhoneOS'.length);
  return version.isEmpty ? null : version;
}

void _validateFramework(KmpProject project, String frameworkPath) {
  if (!Directory(frameworkPath).existsSync()) {
    throw XcrossError('Compose framework not found: $frameworkPath');
  }
  if (!File(p.join(frameworkPath, project.baseName)).existsSync()) {
    throw XcrossError(
      'Compose framework binary not found: ${p.join(frameworkPath, project.baseName)}',
    );
  }
}
