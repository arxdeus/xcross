import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/errors.dart';

@immutable
final class AppleToolShimConfig {
  const AppleToolShimConfig({
    required this.iosSdk,
    required this.clang,
    required this.hostCompiler,
    required this.archiver,
    required this.linker,
    required this.lipo,
    required this.otool,
    required this.installNameTool,
    required this.deploymentTarget,
  });

  final String iosSdk;
  final String clang;
  final String hostCompiler;
  final String archiver;
  final String linker;
  final String lipo;
  final String otool;
  final String installNameTool;
  final String deploymentTarget;

  static Future<AppleToolShimConfig> resolve(String deploymentTarget) async {
    final sdk = DarwinSdk.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Native assets require an installed Darwin SDK. Run '
        '`xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    final clang = await DarwinSdk.resolveDarwinClang(sdk);
    return AppleToolShimConfig(
      iosSdk: sdk.iPhoneOSSdk(),
      clang: clang,
      hostCompiler: await ProcessRunner.locateTool('cc'),
      archiver: await _locateArchiver(clang),
      linker: await DarwinSdk.resolveLd64Lld(sdk),
      lipo: await locateLlvmTool('llvm-lipo'),
      otool: await locateLlvmTool('llvm-otool'),
      installNameTool: await locateLlvmTool('llvm-install-name-tool'),
      deploymentTarget: deploymentTarget,
    );
  }
}

Future<String> _locateArchiver(String clang) async {
  final besideClang = p.join(
    p.dirname(clang),
    'llvm-ar${Platform.isWindows ? '.exe' : ''}',
  );
  if (File(besideClang).existsSync()) return besideClang;
  return locateLlvmTool('llvm-ar');
}

Future<String> locateLlvmTool(String name) async {
  final tool = await DarwinSdk.locateLlvmTool(
    ProcessRunner.hostExecutableName(name),
  );
  if (tool != null) return tool;
  throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
}

/// Installs the Apple command-line surface needed by Flutter build hooks.
Future<void> installAppleToolShims(
  String directory,
  AppleToolShimConfig config,
) async {
  await Directory(directory).create(recursive: true);
  final compilerShim = p.join(
    directory,
    Platform.isWindows ? 'clang.bat' : 'clang',
  );
  final tools = <String, String>{
    'clang': compilerShim,
    'ar': config.archiver,
    'ld': config.linker,
    'lipo': config.lipo,
    'otool': config.otool,
    'install_name_tool': config.installNameTool,
  };

  if (Platform.isWindows) {
    await File(p.join(directory, 'clang.ps1')).writeAsString(
      renderPowerShellCompilerShim(
        iosSdk: config.iosSdk,
        clang: config.clang,
        hostCompiler: config.hostCompiler,
        linker: config.linker,
        deploymentTarget: config.deploymentTarget,
      ),
    );
    await _writeWindowsShim(
      directory,
      'clang',
      renderBatchPowerShellShim('clang.ps1'),
    );
    await _writeWindowsShim(
      directory,
      'cc',
      renderBatchPowerShellShim('clang.ps1'),
    );
    await File(p.join(directory, 'xcrun.ps1')).writeAsString(
      renderPowerShellXcrunShim(iosSdk: config.iosSdk, tools: tools),
    );
    await _writeWindowsShim(
      directory,
      'xcrun',
      renderBatchPowerShellShim('xcrun.ps1'),
    );
    for (final tool in tools.entries.skip(3)) {
      await _writeWindowsShim(
        directory,
        tool.key,
        renderBatchToolShim(tool.value),
      );
    }
    await _writeWindowsShim(directory, 'codesign', batchCodesignShim);
    return;
  }

  final compilerScript = renderUnixCompilerShim(
    iosSdk: config.iosSdk,
    clang: config.clang,
    hostCompiler: config.hostCompiler,
    linker: config.linker,
    deploymentTarget: config.deploymentTarget,
  );
  await _writeUnixShim(directory, 'clang', compilerScript);
  await _writeUnixShim(directory, 'cc', compilerScript);
  await _writeUnixShim(
    directory,
    'xcrun',
    renderUnixXcrunShim(iosSdk: config.iosSdk, tools: tools),
  );
  for (final tool in tools.entries.skip(3)) {
    await _writeUnixShim(directory, tool.key, renderUnixToolShim(tool.value));
  }
  await _writeUnixShim(directory, 'codesign', unixCodesignShim);
}

Future<void> _writeUnixShim(
  String directory,
  String name,
  String contents,
) async {
  final file = File(p.join(directory, name));
  await file.writeAsString(contents);
  ProcessRunner.makeExecutable(file.path);
}

Future<void> _writeWindowsShim(
  String directory,
  String name,
  String contents,
) => File(p.join(directory, '$name.bat')).writeAsString(contents);
