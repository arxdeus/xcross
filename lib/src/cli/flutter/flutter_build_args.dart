import 'package:args/command_runner.dart';
import 'package:xcross/src/build/flutter_pack_operation.dart';
import 'package:xcross/src/cli/shared/ipa_packager.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/logging.dart';

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

/// `xcross flutter build` — build a Flutter iOS `.app` (optionally sign / ipa).
///
/// xcross is debug-only and cannot sign: the original xtool has no standalone
/// sign command, so signing only happens at install time. Accepts the xtool
/// `--ipa` flag plus the official `flutter build ios` flags (`-t/--target`,
/// `-D/--dart-define`, `--dart-define-from-file`, `--[no-]pub`, `--build-name`,
/// `--build-number`, `--flavor`).
class FlutterBuildCommand extends Command<void> with CommonFlutterOptions {
  FlutterBuildCommand() {
    addCommonFlutterOptions();
    argParser
      ..addOption(
        'build-name',
        help: 'Version name (CFBundleShortVersionString).',
      )
      ..addOption(
        'build-number',
        help: 'Version code (CFBundleVersion).',
      )
      ..addFlag(
        'sign',
        abbr: 's',
        help: 'Unsupported — xcross signs at install time, not build time.',
        negatable: false,
      )
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
  String get description =>
      'Build a Flutter iOS .app from Linux without Xcode.';

  String? get _buildName => argResults!.option('build-name');
  String? get _buildNumber => argResults!.option('build-number');
  bool get _sign => argResults!.flag('sign');
  bool get _ipa => argResults!.flag('ipa');

  @override
  Future<void> run() async {
    if (_sign) {
      // Upstream xtool has no standalone "sign" command; signing happens at
      // install time. Fail before building rather than after.
      throw UsageException(
        'xcross cannot sign a .app: the original xtool has no standalone sign '
            'command.',
        'Use `xcross flutter run` or `xtool install <app>` to sign + install.',
      );
    }

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

    final finalPath =
        _ipa ? await IpaPackager.package(result.appPath) : result.appPath;
    Log.logDone('Wrote $finalPath');
  }
}
