import 'package:xcross_flutter/src/models/flutter/dart_defines.dart';

/// Options shared by `xcross flutter build` and `run`, mirroring the semantics
/// of the official `flutter build ios` / `flutter run` arguments.
///
/// xcross is debug-only, so there is no build-mode field.
final class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
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
  );

  /// `-t/--target` entrypoint.
  final String target;

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
