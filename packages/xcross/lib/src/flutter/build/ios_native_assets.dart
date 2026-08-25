import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/flutter/errors.dart';

/// Native code assets produced by Flutter's Dart build-hook pipeline.
@immutable
final class IosNativeAssetsBuildResult {
  const IosNativeAssetsBuildResult({
    required this.manifestPath,
    required this.frameworks,
  });

  final String manifestPath;
  final List<String> frameworks;
}

/// Runs Flutter's native-assets targets without replacing xcross's custom
/// kernel/App.framework build.
final class IosNativeAssetsBuilder {
  IosNativeAssetsBuilder({
    required this.projectRoot,
    required this.flutterRoot,
    required this.deploymentTarget,
    this.entrypoint = 'lib/main.dart',
  });

  final String projectRoot;
  final String flutterRoot;
  final IosDeploymentTarget deploymentTarget;
  final String entrypoint;

  Future<IosNativeAssetsBuildResult> build() async {
    final output = p.join(projectRoot, 'build', 'xcross-native-assets');
    final outputDir = Directory(output);
    if (outputDir.existsSync()) await outputDir.delete(recursive: true);
    await outputDir.create(recursive: true);
    if (!hasBuildHooks(projectRoot)) {
      final manifest = p.join(output, 'NativeAssetsManifest.json');
      await File(
        manifest,
      ).writeAsString('{"format-version":[1,0,0],"native-assets":{}}');
      return IosNativeAssetsBuildResult(
        manifestPath: manifest,
        frameworks: const [],
      );
    }

    final sdk = DarwinSdk.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Native assets require an installed Darwin SDK. Run '
        '`xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    final iosSdk = sdk.iPhoneOSSdk();
    final clang = await DarwinSdk.resolveDarwinClang(sdk);
    final linker = await DarwinSdk.resolveLd64Lld(sdk);
    // Resolve before prepending the shim directory to PATH: Cargo build scripts
    // invoke plain `cc` for HOST artifacts as well as iOS target artifacts.
    final hostCompiler = await ProcessRunner.locateTool('cc');
    final archiver = await _locateArchiver(clang);
    final lipo = await _locateLlvmTool('llvm-lipo');
    final otool = await _locateLlvmTool('llvm-otool');
    final installNameTool = await _locateLlvmTool('llvm-install-name-tool');

    final shims = await Directory.systemTemp.createTemp('xcross-apple-tools-');
    try {
      await writeAppleToolShims(
        shims.path,
        iosSdk: iosSdk,
        clang: clang,
        hostCompiler: hostCompiler,
        archiver: archiver,
        linker: linker,
        deploymentTarget: deploymentTarget.version,
        lipo: lipo,
        otool: otool,
        installNameTool: installNameTool,
      );
      final flutter = p.join(
        flutterRoot,
        'bin',
        ProcessRunner.hostExecutableName('flutter', windowsExtension: '.bat'),
      );
      await ProcessRunner.runChecked(
        flutter,
        [
          'assemble',
          '--no-version-check',
          '-o',
          output,
          '-dTargetPlatform=ios',
          '-dBuildMode=debug',
          '-dIosArchs=arm64',
          '-dSdkRoot=$iosSdk',
          '-dTargetFile=$entrypoint',
          '-dIosDeploymentTarget=${deploymentTarget.version}',
          'debug_ios_bundle_flutter_assets',
        ],
        workingDirectory: projectRoot,
        // Flutter's hook runner sanitizes its environment. The tool shims
        // therefore embed their resolved paths rather than reading XCROSS_*.
        environment: {
          'PATH':
              '${shims.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}',
        },
        inheritStdio: Log.isVerbose,
        label: 'Flutter native assets',
      );
    } finally {
      await shims.delete(recursive: true);
    }

    final manifest = p.join(
      output,
      'App.framework',
      'flutter_assets',
      'NativeAssetsManifest.json',
    );
    if (!File(manifest).existsSync()) {
      throw FlutterBuildError(
        'Flutter native-assets build did not produce $manifest',
      );
    }

    final nativeAssets = Directory(p.join(output, 'native_assets'));
    final frameworks = nativeAssets.existsSync()
        ? nativeAssets
              .listSync()
              .whereType<Directory>()
              .where((directory) {
                return directory.path.endsWith('.framework');
              })
              .map((directory) => directory.path)
              .toList()
        : <String>[];
    return IosNativeAssetsBuildResult(
      manifestPath: manifest,
      frameworks: frameworks,
    );
  }

  /// Whether any package in the resolved package graph has a build hook.
  @visibleForTesting
  static bool hasBuildHooks(String projectRoot) {
    final packageConfig = File(
      p.join(projectRoot, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfig.existsSync()) return false;
    final json = jsonDecode(packageConfig.readAsStringSync());
    if (json is! Map<String, Object?> || json['packages'] is! List) {
      return false;
    }
    final configUri = packageConfig.uri;
    for (final package in json['packages']! as List) {
      if (package is! Map<String, Object?> || package['rootUri'] is! String) {
        continue;
      }
      final root = configUri.resolve(package['rootUri']! as String);
      final rootDirectory = Uri.directory(root.toFilePath());
      if (File.fromUri(rootDirectory.resolve('hook/build.dart')).existsSync()) {
        return true;
      }
    }
    return false;
  }

  Future<String> _locateArchiver(String clang) async {
    final besideClang = p.join(
      p.dirname(clang),
      'llvm-ar${Platform.isWindows ? '.exe' : ''}',
    );
    if (File(besideClang).existsSync()) return besideClang;
    return _locateLlvmTool('llvm-ar');
  }

  static Future<String> _locateLlvmTool(String name) async {
    final executable = ProcessRunner.hostExecutableName(name);
    final tool = await DarwinSdk.locateLlvmTool(executable);
    if (tool != null) return tool;
    throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
  }

  /// Writes just enough of Apple's command-line surface for Flutter's debug,
  /// single-arm64 native-assets pipeline on non-macOS hosts.
  @visibleForTesting
  static Future<void> writeAppleToolShims(
    String directory, {
    required String iosSdk,
    required String clang,
    required String hostCompiler,
    required String archiver,
    required String linker,
    required String deploymentTarget,
    String? lipo,
    String? otool,
    String? installNameTool,
  }) async {
    await Directory(directory).create(recursive: true);
    final resolvedLipo = lipo ?? await _locateLlvmTool('llvm-lipo');
    final resolvedOtool = otool ?? await _locateLlvmTool('llvm-otool');
    final resolvedInstallNameTool =
        installNameTool ?? await _locateLlvmTool('llvm-install-name-tool');
    final compilerShim = p.join(
      directory,
      Platform.isWindows ? 'clang.bat' : 'clang',
    );
    final tools = {
      // Flutter records `xcrun --find clang` in the build-hook C compiler
      // configuration. Return the shim, not the host clang, so that nested
      // hook processes retain the cross-compilation configuration.
      'clang': compilerShim,
      'ar': archiver,
      'ld': linker,
      'lipo': resolvedLipo,
      'otool': resolvedOtool,
      'install_name_tool': resolvedInstallNameTool,
    };
    if (Platform.isWindows) {
      final powerShellTools = tools.entries
          .map((tool) => '${tool.key} = ${_powerShellQuote(tool.value)}')
          .join('; ');
      await File(p.join(directory, 'clang.ps1')).writeAsString('''
param([Parameter(ValueFromRemainingArguments = \$true)][string[]]\$Arguments)
\$isAppleTarget = \$false; \$hasTarget = \$false; \$hasSysroot = \$false; \$hasDeployment = \$false
\$hasFuseLd = \$false; \$hasLdPath = \$false
for (\$i = 0; \$i -lt \$Arguments.Count; \$i++) {
  \$arg = \$Arguments[\$i]
  \$target = if (\$arg -eq '-target' -or \$arg -eq '--target') { if (++\$i -lt \$Arguments.Count) { \$Arguments[\$i] } } elseif (\$arg -like '-target=*' -or \$arg -like '--target=*') { \$arg.Substring(\$arg.IndexOf('=') + 1) } else { \$null }
  if (\$null -ne \$target) { \$hasTarget = \$true; if (\$target -like '*-apple-*') { \$isAppleTarget = \$true }; continue }
  if (\$arg -eq '-arch' -or \$arg -like '-arch=*' -or \$arg -like '-miphoneos-version-min=*' -or \$arg -like '-mios-simulator-version-min=*') { \$isAppleTarget = \$true }
  if (\$arg -eq '-isysroot' -or \$arg -eq '--sysroot' -or \$arg -like '-isysroot=*' -or \$arg -like '--sysroot=*') { \$hasSysroot = \$true }
  if (\$arg -like '-miphoneos-version-min=*') { \$hasDeployment = \$true }
  if (\$arg -like '-fuse-ld=*') { \$hasFuseLd = \$true }
  if (\$arg -like '--ld-path=*') { \$hasLdPath = \$true }
}
if (!\$isAppleTarget) { & ${_powerShellQuote(hostCompiler)} @Arguments; exit \$LASTEXITCODE }
\$defaults = @()
if (!\$hasTarget) { \$defaults += '--target=arm64-apple-ios$deploymentTarget' }
if (!\$hasSysroot) { \$defaults += @('-isysroot', ${_powerShellQuote(iosSdk)}) }
if (!\$hasDeployment) { \$defaults += '-miphoneos-version-min=$deploymentTarget' }
if (!\$hasFuseLd) { \$defaults += '-fuse-ld=lld' }
if (!\$hasLdPath) { \$defaults += ${_powerShellQuote('--ld-path=$linker')} }
& ${_powerShellQuote(clang)} @(\$defaults + \$Arguments)
exit \$LASTEXITCODE
''');
      await _writeWindowsShim(directory, 'clang', '''
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0clang.ps1" %*
exit /b %errorlevel%
''');
      await _writeWindowsShim(directory, 'cc', '''
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0clang.ps1" %*
exit /b %errorlevel%
''');
      await File(p.join(directory, 'xcrun.ps1')).writeAsString('''
param([Parameter(ValueFromRemainingArguments = \$true)][string[]]\$Arguments)
\$tools = @{ $powerShellTools }
for (\$i = 0; \$i -lt \$Arguments.Count; \$i++) {
  switch (\$Arguments[\$i]) {
    '--sdk' { \$i++; continue }
    '--show-sdk-path' { Write-Output ${_powerShellQuote(iosSdk)}; exit 0 }
    '--find' {
      if (++\$i -ge \$Arguments.Count -or !\$tools[\$Arguments[\$i]]) { exit 1 }
      Write-Output \$tools[\$Arguments[\$i]]; exit 0
    }
    default {
      if (\$Arguments[\$i] -eq 'codesign') { exit 0 }
      \$tool = \$tools[\$Arguments[\$i]]
      if (!\$tool) { Write-Error "xcrun: unknown tool \$(\$Arguments[\$i])"; exit 1 }
      & \$tool @(\$Arguments[(\$i + 1)..(\$Arguments.Count - 1)])
      exit \$LASTEXITCODE
    }
  }
}
exit 1
''');
      await _writeWindowsShim(directory, 'xcrun', '''
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0xcrun.ps1" %*
exit /b %errorlevel%
''');
      for (final tool in tools.entries.skip(3)) {
        await _writeWindowsShim(
          directory,
          tool.key,
          '@echo off\n"${tool.value}" %*\nexit /b %errorlevel%\n',
        );
      }
      await _writeWindowsShim(directory, 'codesign', '@echo off\nexit /b 0\n');
    } else {
      final compilerScript =
          '''
#!/bin/sh
is_apple_target=false
has_target=false
has_sysroot=false
has_deployment=false
has_fuse_ld=false
has_ld_path=false
expect_target=false
for arg in "\$@"; do
  if \$expect_target; then
    has_target=true
    case "\$arg" in *-apple-*) is_apple_target=true;; esac
    expect_target=false
    continue
  fi
  case "\$arg" in
    -target|--target) expect_target=true;;
    -target=*|--target=*)
      has_target=true
      case "\${arg#*=}" in *-apple-*) is_apple_target=true;; esac;;
    -arch|-arch=*) is_apple_target=true;;
    -miphoneos-version-min=*) is_apple_target=true; has_deployment=true;;
    -mios-simulator-version-min=*) is_apple_target=true;;
    -isysroot|--sysroot|-isysroot=*|--sysroot=*) has_sysroot=true;;
    -fuse-ld=*) has_fuse_ld=true;;
    --ld-path=*) has_ld_path=true;;
  esac
done
\$is_apple_target || exec ${_shellQuote(hostCompiler)} "\$@"
\$has_ld_path || set -- ${_shellQuote('--ld-path=$linker')} "\$@"
\$has_fuse_ld || set -- ${_shellQuote('-fuse-ld=lld')} "\$@"
\$has_deployment || set -- ${_shellQuote('-miphoneos-version-min=$deploymentTarget')} "\$@"
\$has_sysroot || set -- ${_shellQuote('-isysroot')} ${_shellQuote(iosSdk)} "\$@"
\$has_target || set -- ${_shellQuote('--target=arm64-apple-ios$deploymentTarget')} "\$@"
exec ${_shellQuote(clang)} "\$@"
''';
      await _writeUnixShim(directory, 'clang', compilerScript);
      await _writeUnixShim(directory, 'cc', compilerScript);
      final script =
          '''
#!/bin/sh
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --sdk) shift; [ "\$#" -gt 0 ] && shift;;
    --show-sdk-path) echo ${_shellQuote(iosSdk)}; exit 0;;
    --find)
      shift
      case "\${1-}" in
        clang) echo ${_shellQuote(compilerShim)};; ar) echo ${_shellQuote(archiver)};; ld) echo ${_shellQuote(linker)};;
        lipo) echo ${_shellQuote(resolvedLipo)};; otool) echo ${_shellQuote(resolvedOtool)};;
        install_name_tool) echo ${_shellQuote(resolvedInstallNameTool)};;
        *) exit 1;;
      esac
      exit 0;;
    *)
      tool="\$1"; shift
      case "\$tool" in
        clang) exec ${_shellQuote(compilerShim)} "\$@";; ar) exec ${_shellQuote(archiver)} "\$@";;
        ld) exec ${_shellQuote(linker)} "\$@";; lipo) exec ${_shellQuote(resolvedLipo)} "\$@";;
        otool) exec ${_shellQuote(resolvedOtool)} "\$@";;
        install_name_tool) exec ${_shellQuote(resolvedInstallNameTool)} "\$@";;
        codesign) exit 0;;
        *) echo "xcrun: unknown tool \$tool" >&2; exit 1;;
      esac;;
  esac
done
exit 1
''';
      await _writeUnixShim(directory, 'xcrun', script);
      for (final tool in tools.entries.skip(3)) {
        await _writeUnixShim(
          directory,
          tool.key,
          '#!/bin/sh\nexec ${_shellQuote(tool.value)} "\$@"\n',
        );
      }
      await _writeUnixShim(directory, 'codesign', '#!/bin/sh\nexit 0\n');
    }
  }

  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";

  static String _powerShellQuote(String value) =>
      "'${value.replaceAll("'", "''")}'";

  static Future<void> _writeUnixShim(
    String directory,
    String name,
    String contents,
  ) async {
    final file = File(p.join(directory, name));
    await file.writeAsString(contents);
    ProcessRunner.makeExecutable(file.path);
  }

  static Future<void> _writeWindowsShim(
    String directory,
    String name,
    String contents,
  ) => File(p.join(directory, '$name.bat')).writeAsString(contents);
}
