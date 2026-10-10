import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';

/// The `FLUTTER_VERSION`-family dart-defines flutter_tools adds to every
/// build (`FlutterCommand.flutterVersionDartDefines`), read from the SDK's
/// `bin/cache/flutter.version.json`.
@internal
abstract final class FlutterVersionDefines {
  static List<String> read(PlatformHostInterface host, String flutterRoot) {
    final file = host.fileSystem.file(
      host.paths.context.join(
        flutterRoot,
        'bin',
        'cache',
        'flutter.version.json',
      ),
    );
    if (!file.existsSync()) return const [];
    try {
      return fromJson(jsonDecode(file.readAsStringSync()));
    } on FormatException {
      return const [];
    }
  }

  @visibleForTesting
  static List<String> fromJson(Object? document) {
    if (document case {
      'frameworkVersion': final String version,
      'channel': final String channel,
      'repositoryUrl': final String repositoryUrl,
      'frameworkRevision': final String frameworkRevision,
      'engineRevision': final String engineRevision,
      'dartSdkVersion': final String dartSdkVersion,
    }) {
      return [
        'FLUTTER_VERSION=$version',
        'FLUTTER_CHANNEL=$channel',
        'FLUTTER_GIT_URL=$repositoryUrl',
        'FLUTTER_FRAMEWORK_REVISION=${_short(frameworkRevision)}',
        'FLUTTER_ENGINE_REVISION=${_short(engineRevision)}',
        'FLUTTER_DART_VERSION=$dartSdkVersion',
      ];
    }
    return const [];
  }

  static String _short(String revision) =>
      revision.length > 10 ? revision.substring(0, 10) : revision;
}
