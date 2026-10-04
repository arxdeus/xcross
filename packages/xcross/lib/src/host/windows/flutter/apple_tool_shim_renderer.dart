import 'dart:convert';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/windows/flutter/apple_tool_shim_templates.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';

final class WindowsAppleToolShimRenderer<T extends WindowsHostInterface>
    implements AppleToolShimRenderer<T> {
  WindowsAppleToolShimRenderer(this.host);
  @override
  final T host;
  @override
  Future<void> install(
    String directory,
    AppleToolShimConfig config, {

    String? toolForwarderExecutable,
  }) async {
    final otoolShim = host.paths.context.join(directory, 'otool.bat');
    final auxiliaryTools = <String, String>{
      'lipo': config.lipo,
      if (config.otool != null) 'otool': otoolShim,
      if (config.installNameTool case final tool?) 'install_name_tool': tool,
    };
    await host.fileSystem.directory(directory).create(recursive: true);

    if (toolForwarderExecutable == null) {
      throw missingNativeAssetToolForwarderError();
    }
    for (final entry in {
      'clang': config.clang,
      'cc': config.clang,
      'ar': config.archiver,
      'ld': config.linker,
    }.entries) {
      final executable = host.paths.context.join(directory, '${entry.key}.exe');
      await host.fileSystem
          .file(toolForwarderExecutable)
          .copy(host.paths.ioPath(executable));
      await host.fileSystem.file('$executable.path').writeAsString(entry.value);
      if (entry.key == 'clang' || entry.key == 'cc') {
        await host.fileSystem
            .file('$executable.args')
            .writeAsString(
              jsonEncode([
                '--target=${config.target.buildTriple(config.deploymentTarget)}',
                '-isysroot',
                config.iosSdk,
                config.target.minimumVersionFlag(config.deploymentTarget),
                '-fuse-ld=lld',
                '--ld-path=${config.linker}',
                '-Wl,-arch,arm64',
                '-Wl,-platform_version,${config.target.linkerPlatform},${config.deploymentTarget},26.5',
              ]),
            );
      }
    }
    final xcrunShim = host.paths.context.join(directory, 'xcrun.exe');
    await host.fileSystem.file(config.xcrun).copy(host.paths.ioPath(xcrunShim));
    await host.fileSystem.file('$xcrunShim.sdk').writeAsString(config.iosSdk);
    await host.fileSystem
        .file(toolForwarderExecutable)
        .copy(
          host.paths.ioPath(host.paths.context.join(directory, 'plutil.exe')),
        );

    if (config.otool case final otool?) {
      await host.fileSystem
          .file(host.paths.context.join(directory, 'otool.ps1'))
          .writeAsString(
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
      await _writeWindowsShim(
        directory,
        'install_name_tool',
        batchCodesignShim,
      );
    }
    await _writeWindowsShim(directory, 'codesign', batchCodesignShim);
    await host.fileSystem
        .file(host.paths.context.join(directory, 'rsync.ps1'))
        .writeAsString(r'''
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

  Future<void> _writeWindowsShim(
    String directory,
    String name,
    String contents,
  ) => host.fileSystem
      .file(host.paths.context.join(directory, '$name.bat'))
      .writeAsString(contents);
}
