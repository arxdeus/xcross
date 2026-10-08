import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/shared/flutter/build/ios_deployment_target.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/flutter_build_runtime.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// Locates the iOS AOT compiler (`gen_snapshot`) for a Flutter SDK.
@internal
typedef IosAotCompilerLocator =
    Future<String> Function({
      required String flutterRoot,
      required IosGenSnapshotMode mode,
    });

/// Compiles an AOT kernel into `App.framework/App` the way `flutter build
/// ios` does: `gen_snapshot --snapshot_kind=app-aot-macho-dylib` writes the
/// final Mach-O dylib, with no assembler or linker step.
@internal
final class FlutterAotSnapshotter<T extends PlatformHostInterface> {
  FlutterAotSnapshotter({
    required this.runtime,
    required this.compiler,
    required this.deploymentTarget,
  });

  final FlutterBuildRuntime<T> runtime;

  /// The `gen_snapshot` executable for the build mode.
  final String compiler;
  final IosDeploymentTarget deploymentTarget;

  /// Flutter's iOS deployment floor; flutter_tools passes this, not the app's
  /// deployment target, to `--macho-min-os-version`.
  static const minimumOsVersion = '15.0';

  /// Writes `<appFramework>/App` from [appDill]. The relocatable object goes
  /// to [objectFile]; its path is recorded in the dylib's debug map, so keep
  /// it stable for reproducible output.
  Future<void> compile({
    required String appDill,
    required String appFramework,
    required String objectFile,
    String? splitDebugInfo,
    bool obfuscate = false,
  }) async {
    final binary = p.join(appFramework, 'App');
    await runtime.host.fileSystem
        .directory(appFramework)
        .create(recursive: true);
    if (splitDebugInfo != null) {
      await runtime.host.fileSystem
          .directory(splitDebugInfo)
          .create(recursive: true);
    }
    await runtime.runner.log.logStep(
      'Compiling Dart to native code',
      () => runtime.runner.runChecked(
        compiler,
        arguments(
          appDill: appDill,
          binary: binary,
          objectFile: objectFile,
          splitDebugInfo: splitDebugInfo,
          obfuscate: obfuscate,
        ),
        inheritStdio: runtime.runner.log.isVerbose,
        label: 'gen_snapshot',
      ),
    );
    if (!runtime.host.fileSystem.file(binary).existsSync()) {
      throw FlutterBuildError('gen_snapshot did not produce $binary');
    }
  }

  /// `gen_snapshot` arguments in flutter_tools' order (`base/build.dart`).
  @visibleForTesting
  static List<String> arguments({
    required String appDill,
    required String binary,
    required String objectFile,
    String? splitDebugInfo,
    bool obfuscate = false,
  }) => [
    '--deterministic',
    '--snapshot_kind=app-aot-macho-dylib',
    '--macho=$binary',
    '--macho-object=$objectFile',
    '--macho-min-os-version=$minimumOsVersion',
    '--macho-rpath=@executable_path/Frameworks,@loader_path/Frameworks',
    '--macho-install-name=@rpath/App.framework/App',
    if (splitDebugInfo != null) ...[
      '--dwarf-stack-traces',
      '--resolve-dwarf-paths',
      '--save-debugging-info=${p.join(splitDebugInfo, 'app.ios-arm64.symbols')}',
    ],
    if (obfuscate) '--obfuscate',
    appDill,
  ];
}
