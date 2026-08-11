import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/compose/build/compose_pack_operation.dart';
import 'package:xcross/src/compose/models/compose_build_options.dart';
import 'package:xcross/src/models/pack_result.dart';

part 'compose_build_command.g.dart';

typedef ComposeCliPackOperation =
    Future<PackResult> Function({
      required ComposeBuildOptions options,
      required bool requireRunnableApp,
    });
typedef ComposeIpaPackage = Future<String> Function(String appPath);
typedef ComposeLogDone = void Function(String message);

@CliOptions(createCommand: true)
final class ComposeBuildArgs {
  @CliOption(
    defaultsTo: ComposeConfiguration.debug,
    help: 'Build configuration: debug or release.',
  )
  late ComposeConfiguration configuration;

  @CliOption(help: 'Override CFBundleIdentifier.')
  late String? bundleId;

  @CliOption(help: 'Override the iOS product name.')
  late String? appName;

  @CliOption(
    negatable: false,
    help:
        'Output a .ipa file instead of a .app when the project produces an app.',
  )
  late bool ipa;
}

final class ComposeBuildCommand extends _$ComposeBuildArgsCommand<void> {
  ComposeBuildCommand()
    : this.withSeams(
        packOperation: _defaultPackOperation,
        packageIpa: IpaPackager.package,
        logDone: Log.logDone,
      );

  ComposeBuildCommand.withSeams({
    required ComposeCliPackOperation packOperation,
    required ComposeIpaPackage packageIpa,
    required ComposeLogDone logDone,
  }) : _packOperation = packOperation,
       _packageIpa = packageIpa,
       _logDone = logDone;

  final ComposeCliPackOperation _packOperation;
  final ComposeIpaPackage _packageIpa;
  final ComposeLogDone _logDone;

  @override
  String get name => 'build';

  @override
  String get description =>
      'Build a Compose Multiplatform iOS .app or .framework without Xcode.';

  @override
  Future<void> run() async {
    final options = ComposeBuildOptions(
      configuration: _options.configuration,
      bundleId: _options.bundleId,
      appName: _options.appName,
      ipa: _options.ipa,
    );
    final result = await _packOperation(
      options: options,
      requireRunnableApp: false,
    );
    final finalPath = _options.ipa && result.kind == PackOutputKind.app
        ? await _packageIpa(result.appPath)
        : result.outputPath;
    _logDone('Wrote $finalPath');
  }

  static Future<PackResult> _defaultPackOperation({
    required ComposeBuildOptions options,
    required bool requireRunnableApp,
  }) => ComposePackOperation.pack(
    options: options,
    requireRunnableApp: requireRunnableApp,
  );
}
