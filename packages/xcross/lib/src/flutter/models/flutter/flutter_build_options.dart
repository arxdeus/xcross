import 'package:xcross/src/flutter/errors.dart';
import 'package:xcross/src/flutter/models/flutter/dart_defines.dart';

/// Options shared by `xcross flutter build` and `run`, mirroring the semantics
/// of the official `flutter build ios` / `flutter run` arguments.
///
final class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
    this.simulator = false,
    this.buildMode = 'debug',
  });

  /// Build options from raw CLI arguments, merging `--dart-define-from-file`
  /// entries (lower precedence) with explicit `--dart-define` entries.
  static Future<FlutterBuildOptions> resolve({
    required String target,
    required List<String> dartDefine,
    required List<String> dartDefineFromFile,
    required bool pub,
    String? buildName,
    String? buildNumber,
    String? flavor,
    bool simulator = false,
    String buildMode = 'debug',
  }) async => FlutterBuildOptions(
    target: target,
    dartDefines: await DartDefines.mergeDartDefines(
      dartDefineFromFile,
      dartDefine,
    ),
    pub: pub,
    buildName: buildName,
    buildNumber: buildNumber,
    flavor: flavor,
    simulator: simulator,
    buildMode: buildMode,
  );

  /// `-t/--target` entrypoint.
  final String target;
  final bool simulator;
  final String buildMode;

  void validate() {
    if (buildMode != 'debug') {
      throw FlutterBuildError(
        'xcross Flutter ${simulator ? "iOS Simulator" : "iOS"} builds support debug mode only. Use --debug.',
      );
    }
  }

  /// Merged `--dart-define` + `--dart-define-from-file` values as `KEY=VALUE`
  /// strings (file entries first, explicit `--dart-define` overriding them).
  final List<String> dartDefines;

  /// `--[no-]pub` — whether to run `flutter pub get`.
  final bool pub;

  /// `--build-name` → `CFBundleShortVersionString` (defaults to 1.0.0).
  final String? buildName;

  /// `--build-number` → `CFBundleVersion` (defaults to 1).
  final String? buildNumber;

  /// `--flavor` — sets the `FLUTTER_APP_FLAVOR` dart-define, readable at
  /// runtime via `appFlavor` from `package:flutter/services`.
  final String? flavor;
}
