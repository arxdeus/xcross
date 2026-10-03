import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/cli/internal/parsed_command.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/composition/ios_target.dart';
import 'package:xcross/src/flutter/flutter.dart';
import 'package:xcross/src/shared/runtime/xcross_runtime.dart';

part 'flutter_build_command.g.dart';

/// Shared `flutter build`/`flutter run` options: entry-point target, flavor,
/// dart-defines, and `--pub`.
class CommonFlutterArgs {
  @CliOption(
    abbr: 't',
    defaultsTo: 'lib/main.dart',
    help: 'The main entry-point file of the application.',
  )
  late String target;

  @CliOption(help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).')
  late String? flavor;

  @CliOption(abbr: 'D', help: 'Pass a KEY=VALUE define to the Dart compiler.')
  late List<String> dartDefine;

  @CliOption(help: 'Load dart-defines from a .json or .env file.')
  late List<String> dartDefineFromFile;

  @CliOption(help: 'Run "flutter pub get" before building.', defaultsTo: true)
  late bool pub;
}

/// Options for `xcross flutter build`.
@CliOptions()
final class FlutterBuildArgs extends CommonFlutterArgs {
  @CliOption(
    defaultsTo: 'iphone',
    help: 'Target platform: iphone or simulator.',
  )
  late String targetPlatform;

  @CliOption(
    negatable: false,
    help: 'Build in debug mode (the only supported mode).',
  )
  late bool debug;

  @CliOption(negatable: false, help: 'Profile mode is unsupported by xcross.')
  late bool profile;

  @CliOption(negatable: false, help: 'Release mode is unsupported by xcross.')
  late bool release;

  @CliOption(help: 'Version name (CFBundleShortVersionString).')
  late String? buildName;

  @CliOption(help: 'Version code (CFBundleVersion).')
  late String? buildNumber;

  @CliOption(
    abbr: 'i',
    negatable: false,
    help: 'Output a .ipa file instead of a .app.',
  )
  late bool ipa;
}

/// `xcross flutter build` — build a Flutter iOS `.app` (optionally ipa).
///
/// xcross is debug-only; `build` produces an unsigned bundle and signing
/// happens when `xcross flutter run` installs it.
final class FlutterBuildCommand<T extends PlatformHostInterface>
    extends ParsedCommand<FlutterBuildArgs, void> {
  @override
  ArgParser populateOptions(ArgParser parser) =>
      _$populateFlutterBuildArgsParser(parser);
  @override
  FlutterBuildArgs parseOptions(ArgResults results) =>
      _$parseFlutterBuildArgsResult(results);

  FlutterBuildCommand(this.runtime);

  final XcrossRuntime<T> runtime;
  @override
  String get name => 'build';

  @override
  String get description => 'Build a Flutter iOS .app without Xcode.';

  @override
  Future<void> run() async {
    if ([
          options.debug,
          options.profile,
          options.release,
        ].where((enabled) => enabled).length >
        1) {
      usageException('Choose only one of --debug, --profile or --release.');
    }
    if (options.profile || options.release) {
      usageException(
        'xcross Flutter builds support debug mode only. Use --debug.',
      );
    }
    final features = composeBuildFeatures(
      options.targetPlatform,
      runtime,
      ipa: options.ipa,
    );
    final buildRuntime = features.flutterRuntime;
    final buildOptions = await buildRuntime.options.resolve(
      target: options.target,
      dartDefine: options.dartDefine,
      dartDefineFromFile: options.dartDefineFromFile,
      pub: options.pub,
      buildName: options.buildName,
      buildNumber: options.buildNumber,
      flavor: options.flavor,
    );

    final result = await FlutterPackOperation.pack(
      projectRoot: runtime.host.paths.context.current,
      runtime: buildRuntime,
      options: buildOptions,
    );

    final finalPath = options.ipa
        ? await IpaPackager.package(result.appPath)
        : result.appPath;
    runtime.log.logDone('Wrote $finalPath');
  }
}
