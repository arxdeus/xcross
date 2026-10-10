import 'dart:convert';

import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/errors.dart';

/// Version identity of an installed Flutter SDK.
@internal
final class FlutterSdkRelease {
  const FlutterSdkRelease({
    required this.version,
    required this.engine,
    this.dart,
    this.dartSdkVersion,
  });

  /// Flutter framework version, as Flutter tags it (`3.47.0`).
  final String version;

  /// Engine revision from `bin/internal/engine.version`.
  final String engine;

  /// Dart SDK revision from `bin/cache/dart-sdk/revision`, when present.
  final String? dart;

  /// Dart SDK version from `bin/cache/dart-sdk/version`, when present.
  final String? dartSdkVersion;

  String get shortEngine => engine.length > 8 ? engine.substring(0, 8) : engine;
}

/// Reads [FlutterSdkRelease] from a Flutter SDK checkout.
@internal
final class FlutterSdkReleaseReader {
  const FlutterSdkReleaseReader(this.host);

  final PlatformHostInterface host;

  FlutterSdkRelease read(String flutterRoot) {
    final engine =
        _text(flutterRoot, ['bin', 'internal', 'engine.version']) ??
        _text(flutterRoot, ['bin', 'cache', 'engine.stamp']);
    if (engine == null) {
      throw FlutterBuildError(
        'Could not determine the Flutter engine revision: neither '
        'bin/internal/engine.version nor bin/cache/engine.stamp exists under '
        '$flutterRoot. Run `flutter --version` once to materialize it.',
      );
    }
    final version =
        _frameworkVersion(flutterRoot) ?? _text(flutterRoot, ['version']);
    if (version == null) {
      throw FlutterBuildError(
        'Could not determine the Flutter version: neither '
        'bin/cache/flutter.version.json nor version exists under '
        '$flutterRoot. Run `flutter --version` once to materialize it.',
      );
    }
    return FlutterSdkRelease(
      version: version,
      engine: engine,
      dart: _text(flutterRoot, ['bin', 'cache', 'dart-sdk', 'revision']),
      dartSdkVersion: _text(flutterRoot, [
        'bin',
        'cache',
        'dart-sdk',
        'version',
      ]),
    );
  }

  String? _frameworkVersion(String flutterRoot) {
    final source = _text(flutterRoot, ['bin', 'cache', 'flutter.version.json']);
    if (source == null) return null;
    try {
      final Object? document = jsonDecode(source);
      if (document case {
        'frameworkVersion': final String version,
      } when version.trim().isNotEmpty) {
        return version.trim();
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  String? _text(String flutterRoot, List<String> relative) {
    final file = host.fileSystem.file(
      host.paths.context.joinAll([flutterRoot, ...relative]),
    );
    try {
      if (!file.existsSync()) return null;
      final text = file.readAsStringSync().trim();
      return text.isEmpty ? null : text;
    } on Object {
      return null;
    }
  }
}
