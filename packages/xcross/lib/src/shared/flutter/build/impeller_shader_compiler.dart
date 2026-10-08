import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:cli_kit/shared/process/process.dart';
import 'package:meta/meta.dart';

/// Compiles Flutter fragment programs into the runtime stage the iOS engine
/// loads, the way flutter_tools' `ShaderCompiler` does for `TargetPlatform.ios`.
@internal
final class ImpellerShaderCompiler<T extends PlatformHostInterface> {
  ImpellerShaderCompiler({
    required this.runner,
    required this.impellerc,
    required this.shaderLib,
  });
  final ProcessRunner<T> runner;
  final String impellerc;
  final String shaderLib;

  Future<void> compile({required String source, required String output}) async {
    final fileSystem = runner.host.fileSystem;
    final paths = runner.host.paths.context;
    await fileSystem.directory(paths.dirname(output)).create(recursive: true);
    await runner.runChecked(
      impellerc,
      arguments(source: source, output: output),
      label: 'impellerc',
    );
    final spirv = fileSystem.file('$output.spirv');
    if (spirv.existsSync()) await spirv.delete();
  }

  @visibleForTesting
  List<String> arguments({required String source, required String output}) => [
    '--runtime-stage-metal',
    '--iplr',
    '--sl=$output',
    '--spirv=$output.spirv',
    '--input=$source',
    '--input-type=frag',
    '--include=${runner.host.paths.context.dirname(source)}',
    '--include=$shaderLib',
  ];
}
