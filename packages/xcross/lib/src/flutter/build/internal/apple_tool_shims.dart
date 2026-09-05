import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/errors.dart';

@immutable
final class OtoolConfig {
  const OtoolConfig(this.executable, {required this.usesObjdump});

  final String executable;
  final bool usesObjdump;
}

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
    required this.xcrun,
    required this.deploymentTarget,
  });

  final String iosSdk;
  final String clang;
  final String hostCompiler;
  final String archiver;
  final String linker;
  final String lipo;
  final OtoolConfig? otool;
  final String? installNameTool;
  final String xcrun;
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
      hostCompiler: await resolveHostCompiler(clang),
      archiver: await _locateArchiver(clang),
      linker: await DarwinSdk.resolveLd64Lld(sdk),
      lipo: await locateLlvmTool('llvm-lipo'),
      otool: await resolveOtool(),
      installNameTool: await findLlvmTool('llvm-install-name-tool'),
      xcrun: await resolveXcrun(),
      deploymentTarget: deploymentTarget,
    );
  }
}

String? _launcherOverride;
String? _xcrunOverride;
bool _declarative = false;

/// Configures helper resolution without coupling this layer to config types.
void configureAppleToolShimResolution({
  required bool declarative,
  String? launcher,
  String? xcrun,
}) {
  _launcherOverride = launcher;
  _xcrunOverride = xcrun;
  _declarative = declarative;
}

/// Configures the launcher directory searched for bundled Apple tool shims.
void configureAppleToolShimLauncherOverride(String? launcher) {
  _launcherOverride = launcher;
}

/// Removes configured Apple tool-shim resolution.
void resetAppleToolShimLauncherOverride() {
  _launcherOverride = null;
  _xcrunOverride = null;
  _declarative = false;
}

Future<String> resolveXcrun({String? launcher}) async {
  if (_xcrunOverride case final configured? when configured.isNotEmpty) {
    return configured;
  }
  final effectiveLauncher = _launcherOverride ?? launcher;
  if (effectiveLauncher != null) {
    final sibling = p.join(
      p.dirname(effectiveLauncher),
      ProcessRunner.hostExecutableName('xcrun'),
    );
    if (File(sibling).existsSync()) return sibling;
  }
  if (_declarative) {
    throw FlutterBuildError(
      'xcrun not configured. Set tools.xcrun or configure an xcross launcher '
      'with a bundled xcrun sibling.',
    );
  }
  final platformSibling = p.join(
    p.dirname(Platform.resolvedExecutable),
    ProcessRunner.hostExecutableName('xcrun'),
  );
  if (File(platformSibling).existsSync()) return platformSibling;
  return ProcessRunner.locateTool('xcrun');
}

Future<String> resolveHostCompiler(String clang, {bool? windows}) async =>
    (windows ?? Platform.isWindows) ? clang : ProcessRunner.locateTool('cc');

/// Locates the native `xcross.exe` that Windows tool aliases are copies of.
///
/// native_toolchain_c only recognizes a compiler whose path ends in
/// `clang.exe`, so batch shims cannot stand in for it. Returns null when no
/// native binary is available; callers must fail loudly rather than emit
/// unusable shims.
Future<String?> resolveNativeAssetToolForwarder(
  String executable, {
  bool? windows,
  String? launcher,
  Future<String?> Function()? findInstalled,
}) async {
  if (!(windows ?? Platform.isWindows)) return executable;
  if (_isNativeXcross(executable)) return executable;
  final configured = launcher ?? _launcherOverride;
  if (configured != null &&
      _isNativeXcross(configured) &&
      File(configured).existsSync()) {
    return configured;
  }
  return (findInstalled ?? () => ProcessRunner.which('xcross.exe'))();
}

bool _isNativeXcross(String path) =>
    p.windows.basename(path).toLowerCase() == 'xcross.exe';

FlutterBuildError missingNativeAssetToolForwarderError() => FlutterBuildError(
  "Windows native assets need the native xcross.exe binary: Flutter's "
  'native_toolchain_c only accepts a C compiler named clang.exe, so xcross '
  'installs copies of xcross.exe as clang.exe/cc.exe/ar.exe/ld.exe tool '
  'aliases. No xcross.exe was found (this happens when xcross runs through '
  '`dart run` or a `dart pub global` .bat launcher). Install the xcross '
  'release binary, add its directory to PATH, or set the xcross launcher path '
  'in `xcross config`.',
);

Future<String> _locateArchiver(String clang) async {
  final besideClang = p.join(
    p.dirname(clang),
    'llvm-ar${Platform.isWindows ? '.exe' : ''}',
  );
  if (File(besideClang).existsSync()) return besideClang;
  return locateLlvmTool('llvm-ar');
}

Future<String?> findLlvmTool(String name) =>
    DarwinSdk.locateLlvmTool(ProcessRunner.hostExecutableName(name));

Future<OtoolConfig?> resolveOtool({
  Future<String?> Function(String name) find = findLlvmTool,
}) async {
  final otool = await find('llvm-otool');
  if (otool != null) return OtoolConfig(otool, usesObjdump: false);
  final objdump = await find('llvm-objdump');
  return objdump == null ? null : OtoolConfig(objdump, usesObjdump: true);
}

Future<String> locateLlvmTool(String name) async {
  final tool = await findLlvmTool(name);
  if (tool != null) return tool;
  throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
}

/// Installs the Apple command-line surface needed by Flutter build hooks.
Future<void> installAppleToolShims(
  String directory,
  AppleToolShimConfig config, {
  String? toolForwarderExecutable,
  bool? windows,
}) async {
  final isWindows = windows ?? Platform.isWindows;
  await Directory(directory).create(recursive: true);
  final otoolShim = p.join(directory, isWindows ? 'otool.bat' : 'otool');
  final auxiliaryTools = <String, String>{
    'lipo': config.lipo,
    if (config.otool != null) 'otool': otoolShim,
    if (config.installNameTool case final tool?) 'install_name_tool': tool,
  };

  if (isWindows) {
    await _installWindowsToolShims(
      directory,
      config,
      auxiliaryTools: auxiliaryTools,
      toolForwarderExecutable: toolForwarderExecutable,
    );
    return;
  }

  await _installUnixToolShims(
    directory,
    config,
    auxiliaryTools: auxiliaryTools,
    toolForwarderExecutable: toolForwarderExecutable,
  );
}

Future<void> _installWindowsToolShims(
  String directory,
  AppleToolShimConfig config, {
  required Map<String, String> auxiliaryTools,
  required String? toolForwarderExecutable,
}) async {
  if (toolForwarderExecutable == null) {
    throw missingNativeAssetToolForwarderError();
  }
  for (final entry in {
    'clang': config.clang,
    'cc': config.clang,
    'ar': config.archiver,
    'ld': config.linker,
  }.entries) {
    final executable = p.join(directory, '${entry.key}.exe');
    await File(toolForwarderExecutable).copy(executable);
    await File('$executable.path').writeAsString(entry.value);
    if (entry.key == 'clang' || entry.key == 'cc') {
      await File('$executable.args').writeAsString(
        jsonEncode([
          '--target=arm64-apple-ios${config.deploymentTarget}',
          '-isysroot',
          config.iosSdk,
          '-miphoneos-version-min=${config.deploymentTarget}',
          '-fuse-ld=lld',
          '--ld-path=${config.linker}',
          '-Wl,-arch,arm64',
          '-Wl,-platform_version,ios,${config.deploymentTarget},26.5',
        ]),
      );
    }
  }
  await File(config.xcrun).copy(p.join(directory, 'xcrun.exe'));
  await File(toolForwarderExecutable).copy(p.join(directory, 'plutil.exe'));

  if (config.otool case final otool?) {
    await File(p.join(directory, 'otool.ps1')).writeAsString(
      renderPowerShellOtoolShim(
        tool: otool.executable,
        usesObjdump: otool.usesObjdump,
      ),
    );
    await _writeWindowsShim(
      directory,
      'otool',
      renderBatchPowerShellShim('otool.ps1'),
    );
  }

  for (final tool in auxiliaryTools.entries) {
    if (tool.key != 'otool') {
      await _writeWindowsShim(
        directory,
        tool.key,
        renderBatchToolShim(tool.value),
      );
    }
  }
  if (config.installNameTool == null) {
    await _writeWindowsShim(directory, 'install_name_tool', batchCodesignShim);
  }
  await _writeWindowsShim(directory, 'codesign', batchCodesignShim);
  await File(p.join(directory, 'rsync.ps1')).writeAsString(r'''
$items = @($args | Where-Object { -not $_.StartsWith('-') -and $_ -ne '.DS_Store/' })
if ($items.Count -lt 2) { exit 1 }
$source = $items[$items.Count - 2]
$destination = $items[$items.Count - 1]
Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
exit 0
''');
  await _writeWindowsShim(
    directory,
    'rsync',
    renderBatchPowerShellShim('rsync.ps1'),
  );
}

Future<void> _installUnixToolShims(
  String directory,
  AppleToolShimConfig config, {
  required Map<String, String> auxiliaryTools,
  required String? toolForwarderExecutable,
}) async {
  if (config.otool case final otool?) {
    await _writeUnixShim(
      directory,
      'otool',
      renderUnixOtoolShim(
        tool: otool.executable,
        usesObjdump: otool.usesObjdump,
      ),
    );
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
  await _writeUnixShim(directory, 'xcrun', renderUnixToolShim(config.xcrun));
  if (toolForwarderExecutable != null) {
    await _writeUnixShim(
      directory,
      'plutil',
      renderUnixToolShim(toolForwarderExecutable),
    );
  }

  for (final tool in auxiliaryTools.entries) {
    if (tool.key != 'otool') {
      await _writeUnixShim(directory, tool.key, renderUnixToolShim(tool.value));
    }
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
