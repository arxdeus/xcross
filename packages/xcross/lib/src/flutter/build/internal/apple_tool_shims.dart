import 'dart:convert';
import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:crypto/crypto.dart';
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
  final plan = _buildShimPlan(
    config,
    toolForwarderExecutable: toolForwarderExecutable,
    isWindows: isWindows,
  );
  await Directory(directory).create(recursive: true);
  await _writeShimPlan(directory, plan);
}

/// Content-addresses the Apple tool shim surface so unrelated flutter_tools
/// input-set hashing (which folds `PATH`, and hooks_runner input hashing,
/// which folds `code.c_compiler.*` shim paths) is stable across builds with
/// the same effective toolchain, letting native-assets build-hook caches hit.
Future<String> ensureAppleToolShims(
  String root,
  AppleToolShimConfig config, {
  String? toolForwarderExecutable,
  bool? windows,
}) async {
  final isWindows = windows ?? Platform.isWindows;
  final plan = _buildShimPlan(
    config,
    toolForwarderExecutable: toolForwarderExecutable,
    isWindows: isWindows,
  );
  final key = await _shimPlanKey(plan);
  final target = p.join(root, key);
  if (_hasCompletionMarker(target)) {
    await _pruneOtherShimDirectories(root, keep: key);
    return target;
  }

  await Directory(root).create(recursive: true);
  final temp = await Directory(root).createTemp('.tmp-$key-');
  var published = false;
  try {
    await _writeShimPlan(temp.path, plan);
    await File(_completionMarkerPath(temp.path)).writeAsString(key);
    try {
      await temp.rename(target);
      published = true;
    } on FileSystemException {
      if (_hasCompletionMarker(target)) {
        // A concurrent build already published this key; use it.
      } else if (Directory(target).existsSync()) {
        await Directory(target).delete(recursive: true);
        await temp.rename(target);
        published = true;
      } else {
        rethrow;
      }
    }
  } finally {
    if (!published && temp.existsSync()) {
      await temp.delete(recursive: true);
    }
  }

  await _pruneOtherShimDirectories(root, keep: key);
  return target;
}

String _completionMarkerPath(String dir) => p.join(dir, '.complete');

bool _hasCompletionMarker(String dir) =>
    File(_completionMarkerPath(dir)).existsSync();

Future<void> _pruneOtherShimDirectories(
  String root, {
  required String keep,
}) async {
  try {
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) return;
    final now = DateTime.now();
    await for (final entry in rootDir.list()) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      if (name == keep) continue;
      try {
        if (name.startsWith('.tmp-')) {
          final modified = entry.statSync().modified;
          if (now.difference(modified) < const Duration(hours: 1)) continue;
        }
        await entry.delete(recursive: true);
      } catch (_) {
        // Best-effort: locked directories (e.g. Windows) are left alone.
      }
    }
  } catch (_) {
    // Best-effort pruning; never fail the build over a leaked directory.
  }
}

const _shimPlanFormatVersion = 1;

Future<String> _shimPlanKey(List<_ShimPlanEntry> plan) async {
  final sorted = [...plan]..sort((a, b) => a.name.compareTo(b.name));
  final buffer = StringBuffer('v$_shimPlanFormatVersion\n');
  for (final entry in sorted) {
    switch (entry) {
      case _GeneratedShimEntry(
        name: final name,
        content: final content,
        executable: final executable,
      ):
        buffer
          ..write('generated\u0000$name\u0000${executable ? 1 : 0}\u0000')
          ..write(content.length)
          ..write('\u0000')
          ..write(content)
          ..write('\n');
      case _CopyShimEntry(name: final name, sourcePath: final source):
        final stat = File(source).statSync();
        buffer
          ..write('copy\u0000$name\u0000')
          ..write(p.absolute(source))
          ..write(
            '\u0000${stat.size}\u0000${stat.modified.millisecondsSinceEpoch}',
          )
          ..write('\n');
    }
  }
  final digest = sha256.convert(utf8.encode(buffer.toString()));
  return digest.toString().substring(0, 16);
}

sealed class _ShimPlanEntry {
  const _ShimPlanEntry(this.name);

  final String name;
}

final class _GeneratedShimEntry extends _ShimPlanEntry {
  const _GeneratedShimEntry(
    super.name,
    this.content, {
    required this.executable,
  });

  final String content;
  final bool executable;
}

final class _CopyShimEntry extends _ShimPlanEntry {
  const _CopyShimEntry(super.name, this.sourcePath);

  final String sourcePath;
}

Future<void> _writeShimPlan(String directory, List<_ShimPlanEntry> plan) async {
  for (final entry in plan) {
    final path = p.join(directory, entry.name);
    switch (entry) {
      case _GeneratedShimEntry(
        content: final content,
        executable: final executable,
      ):
        await File(path).writeAsString(content);
        if (executable) ProcessRunner.makeExecutable(path);
      case _CopyShimEntry(sourcePath: final source):
        await File(source).copy(path);
    }
  }
}

List<_ShimPlanEntry> _buildShimPlan(
  AppleToolShimConfig config, {
  required String? toolForwarderExecutable,
  required bool isWindows,
}) {
  final auxiliaryTools = <String, String>{
    'lipo': config.lipo,
    if (config.installNameTool case final tool?) 'install_name_tool': tool,
  };
  return isWindows
      ? _buildWindowsShimPlan(
          config,
          auxiliaryTools: auxiliaryTools,
          toolForwarderExecutable: toolForwarderExecutable,
        )
      : _buildUnixShimPlan(
          config,
          auxiliaryTools: auxiliaryTools,
          toolForwarderExecutable: toolForwarderExecutable,
        );
}

List<_ShimPlanEntry> _buildWindowsShimPlan(
  AppleToolShimConfig config, {
  required Map<String, String> auxiliaryTools,
  required String? toolForwarderExecutable,
}) {
  if (toolForwarderExecutable == null) {
    throw missingNativeAssetToolForwarderError();
  }
  final plan = <_ShimPlanEntry>[];
  for (final entry in {
    'clang': config.clang,
    'cc': config.clang,
    'ar': config.archiver,
    'ld': config.linker,
  }.entries) {
    final exeName = '${entry.key}.exe';
    plan.add(_CopyShimEntry(exeName, toolForwarderExecutable));
    plan.add(
      _GeneratedShimEntry('$exeName.path', entry.value, executable: false),
    );
    if (entry.key == 'clang' || entry.key == 'cc') {
      plan.add(
        _GeneratedShimEntry(
          '$exeName.args',
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
          executable: false,
        ),
      );
    }
  }
  plan.add(_CopyShimEntry('xcrun.exe', config.xcrun));
  plan.add(
    _GeneratedShimEntry('xcrun.exe.sdk', config.iosSdk, executable: false),
  );
  plan.add(_CopyShimEntry('plutil.exe', toolForwarderExecutable));

  if (config.otool case final otool?) {
    plan.add(
      _GeneratedShimEntry(
        'otool.ps1',
        renderPowerShellOtoolShim(
          tool: otool.executable,
          usesObjdump: otool.usesObjdump,
        ),
        executable: false,
      ),
    );
    plan.add(
      _GeneratedShimEntry(
        'otool.bat',
        renderBatchPowerShellShim('otool.ps1'),
        executable: false,
      ),
    );
  }

  for (final tool in auxiliaryTools.entries) {
    plan.add(
      _GeneratedShimEntry(
        '${tool.key}.bat',
        renderBatchToolShim(tool.value),
        executable: false,
      ),
    );
  }
  if (config.installNameTool == null) {
    plan.add(
      const _GeneratedShimEntry(
        'install_name_tool.bat',
        batchCodesignShim,
        executable: false,
      ),
    );
  }
  plan.add(
    const _GeneratedShimEntry(
      'codesign.bat',
      batchCodesignShim,
      executable: false,
    ),
  );
  plan.add(
    const _GeneratedShimEntry('rsync.ps1', r'''
$items = @($args | Where-Object { -not $_.StartsWith('-') -and $_ -ne '.DS_Store/' })
if ($items.Count -lt 2) { exit 1 }
$source = $items[$items.Count - 2]
$destination = $items[$items.Count - 1]
Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
exit 0
''', executable: false),
  );
  plan.add(
    _GeneratedShimEntry(
      'rsync.bat',
      renderBatchPowerShellShim('rsync.ps1'),
      executable: false,
    ),
  );
  return plan;
}

List<_ShimPlanEntry> _buildUnixShimPlan(
  AppleToolShimConfig config, {
  required Map<String, String> auxiliaryTools,
  required String? toolForwarderExecutable,
}) {
  final plan = <_ShimPlanEntry>[];
  if (config.otool case final otool?) {
    plan.add(
      _GeneratedShimEntry(
        'otool',
        renderUnixOtoolShim(
          tool: otool.executable,
          usesObjdump: otool.usesObjdump,
        ),
        executable: true,
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
  plan.add(_GeneratedShimEntry('clang', compilerScript, executable: true));
  plan.add(_GeneratedShimEntry('cc', compilerScript, executable: true));
  // flutter_tools asks `xcrun --find ar` for the archiver, and xcrun prefers
  // PATH. Without this shim that is the host's GNU ar, whose archives carry
  // no Mach-O symbol index, so ld64.lld rejects them ("archive has no index").
  plan.add(
    _GeneratedShimEntry(
      'ar',
      renderUnixToolShim(config.archiver),
      executable: true,
    ),
  );
  plan.add(
    _GeneratedShimEntry(
      'xcrun',
      renderUnixXcrunShim(config.xcrun),
      executable: true,
    ),
  );
  if (toolForwarderExecutable != null) {
    plan.add(
      _GeneratedShimEntry(
        'plutil',
        renderUnixToolShim(toolForwarderExecutable),
        executable: true,
      ),
    );
  }

  for (final tool in auxiliaryTools.entries) {
    plan.add(
      _GeneratedShimEntry(
        tool.key,
        renderUnixToolShim(tool.value),
        executable: true,
      ),
    );
  }
  plan.add(
    const _GeneratedShimEntry('codesign', unixCodesignShim, executable: true),
  );
  return plan;
}
