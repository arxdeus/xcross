import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:xcross/src/shared/flutter/gen_snapshot/ios_gen_snapshot_mode.dart';

/// One compiler archive listed in an xcross_gen_snapshot `manifest.json`.
@internal
final class IosGenSnapshotAsset {
  const IosGenSnapshotAsset({
    required this.sha256,
    required this.executableSha256,
    required this.size,
  });

  /// SHA-256 of the zip archive.
  final String sha256;

  /// SHA-256 of the extracted `gen_snapshot` executable.
  final String executableSha256;

  /// Archive size in bytes.
  final int size;
}

/// The `manifest.json` published with each xcross_gen_snapshot release.
@internal
final class IosGenSnapshotManifest {
  IosGenSnapshotManifest({
    required this.flutter,
    required this.engine,
    required Map<String, IosGenSnapshotAsset> assets,
    this.dart,
  }) : assets = Map.unmodifiable(assets);

  /// Parses [source], throwing [FormatException] for anything that is not a
  /// schema 1 manifest with well-formed digests.
  factory IosGenSnapshotManifest.parse(String source) {
    final Object? document;
    try {
      document = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('manifest.json is not JSON: ${error.message}');
    }
    if (document is! Map<String, Object?>) {
      throw const FormatException('manifest.json must be a JSON object');
    }
    if (document['schema'] case final int schema
        when schema > supportedSchema) {
      throw IosGenSnapshotSchemaException(schema);
    }
    if (document['schema'] != supportedSchema) {
      throw FormatException(
        'Unsupported manifest.json schema ${document['schema']}; '
        'expected $supportedSchema',
      );
    }
    final assets = document['assets'];
    if (assets is! Map<String, Object?>) {
      throw const FormatException('manifest.json assets must be an object');
    }
    return IosGenSnapshotManifest(
      flutter: _string(document, 'flutter'),
      engine: _string(document, 'engine'),
      dart: document['dart'] is String ? document['dart']! as String : null,
      assets: {
        for (final entry in assets.entries)
          entry.key: _asset(entry.key, entry.value),
      },
    );
  }

  static const supportedSchema = 1;

  final String flutter;
  final String engine;
  final String? dart;
  final Map<String, IosGenSnapshotAsset> assets;

  /// Release asset name for [mode] on the xcross_gen_snapshot host [host].
  static String assetName(IosGenSnapshotMode mode, String host) =>
      'gen_snapshot-${mode.name}-$host.zip';

  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  static String _string(Map<String, Object?> document, String key) {
    final value = document[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('manifest.json $key must be a non-empty string');
    }
    return value.trim();
  }

  static IosGenSnapshotAsset _asset(String name, Object? value) {
    if (value is! Map<String, Object?>) {
      throw FormatException('manifest.json asset $name must be an object');
    }
    String digest(String key) {
      final digest = value[key];
      if (digest is! String || !_digest.hasMatch(digest.toLowerCase())) {
        throw FormatException(
          'manifest.json asset $name $key must be a SHA-256 hex digest',
        );
      }
      return digest.toLowerCase();
    }

    final size = value['size'];
    if (size is! int || size < 0) {
      throw FormatException(
        'manifest.json asset $name size must be a non-negative integer',
      );
    }
    return IosGenSnapshotAsset(
      sha256: digest('sha256'),
      executableSha256: digest('executable_sha256'),
      size: size,
    );
  }
}

/// A manifest written for a newer xcross than the one reading it.
@internal
final class IosGenSnapshotSchemaException extends FormatException {
  const IosGenSnapshotSchemaException(this.schema)
    : super('manifest.json uses schema $schema');

  final int schema;
}
