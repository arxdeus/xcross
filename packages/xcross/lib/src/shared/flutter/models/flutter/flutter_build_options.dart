import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

/// Options shared by `xcross flutter build` and `run`, mirroring the semantics
/// of the official `flutter build ios` / `flutter run` arguments.
///
@internal
final class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
    this.buildMode = 'debug',
    this.treeShakeIcons = true,
  });

  /// `-t/--target` entrypoint.
  final String target;
  final String buildMode;

  /// `--[no-]tree-shake-icons`. Like `flutter build`, it only applies to
  /// precompiled (profile/release) builds; debug keeps whole icon fonts so
  /// hot reload can use any glyph.
  final bool treeShakeIcons;

  bool get shakesIcons => treeShakeIcons && buildMode != 'debug';

  void validate() {
    if (buildMode != 'debug') {
      throw FlutterBuildError(
        'xcross Flutter iOS builds support debug mode only. Use --debug.',
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
