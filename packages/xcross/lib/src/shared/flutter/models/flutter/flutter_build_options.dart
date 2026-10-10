import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';
import 'package:xcross/src/shared/flutter/models/flutter/flutter_build_mode.dart';

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
    this.buildMode = FlutterBuildMode.debug,
    this.treeShakeIcons = true,
    this.splitDebugInfo,
    this.obfuscate = false,
  });

  /// `-t/--target` entrypoint.
  final String target;
  final FlutterBuildMode buildMode;

  /// `--[no-]tree-shake-icons`. Like `flutter build`, it only applies to
  /// precompiled (profile/release) builds; debug keeps whole icon fonts so
  /// hot reload can use any glyph.
  final bool treeShakeIcons;

  bool get shakesIcons => treeShakeIcons && buildMode.isPrecompiled;

  /// `--split-debug-info=<dir>`: Dart symbols written outside the app.
  final String? splitDebugInfo;

  /// `--obfuscate`: rename Dart symbols; requires [splitDebugInfo].
  final bool obfuscate;

  /// Rejects combinations `flutter build ios` rejects for this target.
  void validate({required bool supportsPrecompiledModes}) {
    if (buildMode.isPrecompiled && !supportsPrecompiledModes) {
      throw FlutterBuildError(
        '${_capitalized(buildMode.name)} mode is not supported for '
        'simulators. Build for a device or use --debug.',
      );
    }
    if (obfuscate && splitDebugInfo == null) {
      throw FlutterBuildError(
        '--obfuscate can only be used in combination with '
        '--split-debug-info.',
      );
    }
    if (!buildMode.isPrecompiled && (obfuscate || splitDebugInfo != null)) {
      throw FlutterBuildError(
        '--obfuscate and --split-debug-info apply to profile and release '
        'builds only.',
      );
    }
  }

  static String _capitalized(String value) =>
      value[0].toUpperCase() + value.substring(1);

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
