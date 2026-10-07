import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_renderer.dart';
import 'package:xcross/src/host/shared/flutter/apple_tool_shim_templates_posix.dart';
import 'package:xcross/src/shared/flutter/build/internal/apple_tool_shims.dart';

@internal
final class PosixAppleToolShimRenderer<T extends PlatformHostInterface>
    implements AppleToolShimRenderer<T> {
  PosixAppleToolShimRenderer(this.host);
  @override
  final T host;
  @override
  Future<void> install(
    String directory,
    AppleToolShimConfig config, {

    String? toolForwarderExecutable,
  }) async {
    final otoolShim = host.paths.context.join(directory, 'otool');
    final auxiliaryTools = <String, String>{
      'lipo': config.lipo,
      if (config.otool != null) 'otool': otoolShim,
      if (config.installNameTool case final tool?) 'install_name_tool': tool,
    };
    await host.fileSystem.directory(directory).create(recursive: true);

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
      hostCompilerArguments: config.hostCompilerArguments,
      linker: config.linker,
      deploymentTarget: config.deploymentTarget,
      target: config.target,
    );
    await _writeUnixShim(directory, 'clang', compilerScript);
    await _writeUnixShim(directory, 'cc', compilerScript);
    await _writeUnixShim(directory, 'ar', renderUnixToolShim(config.archiver));
    final placeholderSdks = host.paths.context.join(
      directory,
      'placeholder-sdks',
    );
    for (final sdk in xcrunProbedSdks) {
      if (sdk == config.target.sdkName) continue;
      await host.fileSystem
          .directory(host.paths.context.join(placeholderSdks, '$sdk.sdk'))
          .create(recursive: true);
    }
    await _writeUnixShim(
      directory,
      'xcrun',
      renderUnixXcrunShim(
        config.xcrun,
        targetSdk: config.target.sdkName,
        placeholderSdks: placeholderSdks,
      ),
    );
    if (toolForwarderExecutable != null) {
      await _writeUnixShim(
        directory,
        'plutil',
        renderUnixToolShim(toolForwarderExecutable),
      );
    }

    for (final tool in auxiliaryTools.entries) {
      if (tool.key != 'otool') {
        await _writeUnixShim(
          directory,
          tool.key,
          renderUnixToolShim(tool.value),
        );
      }
    }
    await _writeUnixShim(directory, 'codesign', unixCodesignShim);
  }

  Future<void> _writeUnixShim(
    String directory,
    String name,
    String contents,
  ) async {
    final file = host.fileSystem.file(host.paths.context.join(directory, name));
    await file.writeAsString(contents);
    host.fileSystem.makeExecutable(file.path);
  }
}
