import 'package:cli_kit/cli_kit.dart';
import 'package:args/command_runner.dart';
import 'package:xcross_flutter/xcross_flutter.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';

/// Shared `flutter build`/`flutter run` options: entry-point target, flavor,
/// dart-defines, and `--pub`. Mixed into [FlutterBuildCommand] and
/// `FlutterRunCommand` so both stay in sync.
mixin CommonFlutterOptions on Command<void> {
  void addCommonFlutterOptions() {
    argParser
      ..addOption(
        'target',
        abbr: 't',
        help: 'The main entry-point file of the application.',
        defaultsTo: 'lib/main.dart',
      )
      ..addOption(
        'flavor',
        help: 'Build a custom app flavor (sets FLUTTER_APP_FLAVOR).',
      )
      ..addMultiOption(
        'dart-define',
        abbr: 'D',
        help: 'Pass a KEY=VALUE define to the Dart compiler.',
      )
      ..addMultiOption(
        'dart-define-from-file',
        help: 'Load dart-defines from a .json or .env file.',
      )
      ..addFlag(
        'pub',
        help: 'Run "flutter pub get" before building.',
        defaultsTo: true,
      );
  }

  String get target => argResults!.option('target')!;
  String? get flavor => argResults!.option('flavor');
  List<String> get dartDefine => argResults!.multiOption('dart-define');
  List<String> get dartDefineFromFile =>
      argResults!.multiOption('dart-define-from-file');
  bool get pub => argResults!.flag('pub');
}

/// `xcross flutter build` — build a Flutter iOS `.app` (optionally ipa).
///
/// xcross is debug-only; `build` produces an unsigned bundle and signing
/// happens when `xcross flutter run` installs it. Accepts `--ipa` plus the
/// official `flutter build ios` flags (`-t/--target`, `-D/--dart-define`,
/// `--dart-define-from-file`, `--[no-]pub`, `--build-name`, `--build-number`,
/// `--flavor`).
class FlutterBuildCommand extends Command<void> with CommonFlutterOptions {
  FlutterBuildCommand() {
    addCommonFlutterOptions();
    argParser
      ..addOption(
        'build-name',
        help: 'Version name (CFBundleShortVersionString).',
      )
      ..addOption('build-number', help: 'Version code (CFBundleVersion).')
      ..addFlag(
        'ipa',
        abbr: 'i',
        help: 'Output a .ipa file instead of a .app.',
        negatable: false,
      );
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build a Flutter iOS .app without Xcode.';

  String? get _buildName => argResults!.option('build-name');
  String? get _buildNumber => argResults!.option('build-number');
  bool get _ipa => argResults!.flag('ipa');

  @override
  Future<void> run() async {
    final options = await FlutterBuildOptions.resolve(
      target: target,
      dartDefine: dartDefine,
      dartDefineFromFile: dartDefineFromFile,
      pub: pub,
      buildName: _buildName,
      buildNumber: _buildNumber,
      flavor: flavor,
    );

    final result = await FlutterPackOperation.pack(options: options);

    final finalPath = _ipa
        ? await IpaPackager.package(result.appPath)
        : result.appPath;
    Log.logDone('Wrote $finalPath');
  }
}
