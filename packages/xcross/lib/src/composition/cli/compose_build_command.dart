@internal
library;

import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/shared/logging/logging.dart';
import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/shared/cli/internal/parsed_command.dart';
import 'package:xcross/src/shared/cli/shared/ipa_packager.dart';
import 'package:xcross/src/shared/compose/models/compose_build_options.dart';
import 'package:xcross/src/shared/models/pack_result.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

part 'compose_build_command.g.dart';

@internal
typedef ComposeCliPackOperation =
    Future<PackResult> Function({
      required ComposeBuildOptions options,
      required bool requireRunnableApp,
      required String targetPlatform,
    });
@internal
typedef ComposeIpaPackage = Future<String> Function(String appPath);
@internal
typedef ComposeLogDone = void Function(String message);

@internal
@CliOptions()
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

  @CliOption(
    defaultsTo: 'iphone',
    help: 'Target platform: iphone or simulator.',
  )
  late String targetPlatform;

  @CliOption(
    abbr: 'v',
    help: 'Show full Gradle, Kotlin/Native, and linker output.',
    negatable: false,
  )
  late bool verbose;
}

@internal
final class ComposeBuildCommand<T extends PlatformHostInterface>
    extends ParsedCommand<ComposeBuildArgs, void> {
  ComposeBuildCommand(XcrossRuntime<T> runtime)
    : this.withSeams(
        packOperation:
            ({
              required options,
              required requireRunnableApp,
              required targetPlatform,
            }) =>
                composeBuildFeatures(
                  targetPlatform,
                  runtime,
                  ipa: options.ipa,
                ).composeOperation.pack(
                  options: options,
                  requireRunnableApp: requireRunnableApp,
                ),
        packageIpa: IpaPackager(host: runtime.host).package,
        logDone: runtime.log.logDone,
        log: runtime.log,
      );

  ComposeBuildCommand.withSeams({
    required this.log,
    required ComposeCliPackOperation packOperation,
    required ComposeIpaPackage packageIpa,
    required ComposeLogDone logDone,
  }) : _packOperation = packOperation,
       _packageIpa = packageIpa,
       _logDone = logDone;
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateComposeBuildArgsParser(parser);
  @override
  ComposeBuildArgs parseOptions(ArgResults results) =>
      _$parseComposeBuildArgsResult(results);

  final Log log;
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
    if (options.verbose) log.setVerbose();
    final buildOptions = ComposeBuildOptions(
      configuration: options.configuration,
      bundleId: options.bundleId,
      appName: options.appName,
      ipa: options.ipa,
    );
    final result = await _packOperation(
      options: buildOptions,
      requireRunnableApp: false,
      targetPlatform: options.targetPlatform,
    );
    final finalPath = options.ipa && result.kind == PackOutputKind.app
        ? await _packageIpa(result.appPath)
        : result.outputPath;
    _logDone('Wrote $finalPath');
  }
}
