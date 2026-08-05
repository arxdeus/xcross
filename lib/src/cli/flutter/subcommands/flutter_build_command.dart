import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross_flutter/xcross_flutter.dart';

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
@CliOptions(createCommand: true)
class FlutterBuildArgs extends CommonFlutterArgs {
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
class FlutterBuildCommand extends _$FlutterBuildArgsCommand<void> {
  @override
  String get name => 'build';

  @override
  String get description => 'Build a Flutter iOS .app without Xcode.';

  @override
  Future<void> run() async {
    final options = await FlutterBuildOptions.resolve(
      target: _options.target,
      dartDefine: _options.dartDefine,
      dartDefineFromFile: _options.dartDefineFromFile,
      pub: _options.pub,
      buildName: _options.buildName,
      buildNumber: _options.buildNumber,
      flavor: _options.flavor,
    );

    final result = await FlutterPackOperation.pack(options: options);

    final finalPath = _options.ipa
        ? await IpaPackager.package(result.appPath)
        : result.appPath;
    Log.logDone('Wrote $finalPath');
  }
}
