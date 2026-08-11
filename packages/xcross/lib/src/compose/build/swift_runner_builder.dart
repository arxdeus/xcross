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
      toolchain.darwinSdkPath,
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
  final generic = p.join(
    toolchain.darwinSdkPath,
    'Developer',
    'Platforms',
    'iPhoneOS.platform',
    'Developer',
    'SDKs',
    'iPhoneOS.sdk',
  );
  if (Directory(generic).existsSync()) return generic;
  throw XcrossError('iPhoneOS SDK not found under ${toolchain.darwinSdkPath}');
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
