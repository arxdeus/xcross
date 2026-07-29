import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/build/flutter_packer.dart';
import 'package:xcross/src/models/config/pack_schema.dart';
import 'package:xcross/src/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/util/logging.dart';

/// The `.app` path and the iOS bundle identifier produced by [flutterPack].
typedef PackResult = ({String appPath, String bundleId});

/// Build the Flutter iOS `.app` for the project in the current directory.
///
/// Prefers `xtool.yml`, otherwise falls back to the default `com.example`
/// schema, deletes any prior bundle, then packs.
Future<PackResult> flutterPack({
  required FlutterBuildOptions options,
}) async {
  final projectRoot = Directory.current.path;

  final PackSchema schema;
  final configPath = p.join(projectRoot, 'xtool.yml');
  if (File(configPath).existsSync()) {
    schema = await PackSchema.fromFile(configPath);
  } else {
    schema = PackSchema.defaultSchema();
    logWarn(
      "Could not locate configuration file 'xtool.yml'. Using default "
      "configuration with 'com.example' organization ID.",
    );
  }

  final packer =
      FlutterPacker(projectRoot: projectRoot, schema: schema, options: options);
  final bundleId = schema.idSpecifier.formBundleId(packer.appName);

  // Always delete any previous bundle BEFORE packing, otherwise stale binaries
  // from an earlier build get codesigned into the new one.
  final bundleDir = Directory(
      p.join(projectRoot, 'build', 'xtool-ios', '${packer.appName}.app'));
  if (bundleDir.existsSync()) await bundleDir.delete(recursive: true);

  final appPath = await packer.pack();
  return (appPath: appPath, bundleId: bundleId);
}
