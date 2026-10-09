import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

@internal
abstract final class DartDefines {
  static const appFlavor = 'FLUTTER_APP_FLAVOR';
  static const buildName = 'FLUTTER_BUILD_NAME';
  static const buildNumber = 'FLUTTER_BUILD_NUMBER';
  static const enabledFeatureFlags = 'FLUTTER_ENABLED_FEATURE_FLAGS';

  /// Keys of the `FLUTTER_VERSION` family, as flutter_tools names them.
  static const versionKeys = [
    'FLUTTER_VERSION',
    'FLUTTER_CHANNEL',
    'FLUTTER_GIT_URL',
    'FLUTTER_FRAMEWORK_REVISION',
    'FLUTTER_ENGINE_REVISION',
    'FLUTTER_DART_VERSION',
  ];

  /// The complete dart-defines of a build, in flutter_tools' order
  /// (`FlutterCommand.getBuildInfo`): the user [defines], then
  /// `FLUTTER_APP_FLAVOR`, `FLUTTER_BUILD_NAME`, `FLUTTER_BUILD_NUMBER` and
  /// the [versionDefines].
  ///
  /// Unlike flutter_tools, an explicit `FLUTTER_APP_FLAVOR` define is kept
  /// and wins over [flavor]. The other framework keys are rejected with
  /// flutter_tools' wording, including `FLUTTER_BUILD_NAME`/
  /// `FLUTTER_BUILD_NUMBER` set in the [environment].
  static List<String> resolve(
    List<String> defines, {
    String? flavor,
    String? buildName,
    String? buildNumber,
    List<String> versionDefines = const [],
    String? Function(String name)? environment,
  }) {
    final result = [...defines];
    if (flavor != null && !_isSet(result, appFlavor)) {
      result.add('$appFlavor=$flavor');
    }
    for (final (key, value) in [
      (DartDefines.buildName, buildName),
      (DartDefines.buildNumber, buildNumber),
    ]) {
      if (environment?.call(key) != null) {
        throw FlutterBuildError(
          '$key is used by the framework and cannot be set in the '
          'environment.',
        );
      }
      if (_isSet(result, key)) {
        throw FlutterBuildError(
          '$key is used by the framework and cannot be set using '
          '$_defineOptions',
        );
      }
      if (value != null) result.add('$key=$value');
    }
    for (final key in versionKeys) {
      if (result.any((define) => define.startsWith(key))) {
        throw FlutterBuildError(
          '$key is used by the framework and cannot be set using '
          '$_defineOptions. Use FlutterVersion to access it in Flutter code',
        );
      }
    }
    result.addAll(versionDefines);
    if (result.any((define) => define.startsWith(enabledFeatureFlags))) {
      throw FlutterBuildError(
        '$enabledFeatureFlags is used by the framework and cannot be set '
        'using $_defineOptions.\n'
        '\n'
        'Use the "flutter config" command to enable feature flags.',
      );
    }
    return result;
  }

  static const _defineOptions = '--dart-define or --dart-define-from-file';

  static bool _isSet(List<String> defines, String key) =>
      defines.any((define) => define == key || define.startsWith('$key='));
}
