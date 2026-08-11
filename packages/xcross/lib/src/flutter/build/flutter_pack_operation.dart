import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/flutter_packer.dart';
import 'package:xcross/src/flutter/build/ios_bundle_id.dart';
import 'package:xcross/src/flutter/models/flutter/flutter_build_options.dart';
import 'package:xcross/src/models/pack_result.dart';

/// Groups the Flutter iOS `.app` packing entrypoint.
abstract final class FlutterPackOperation {
  /// Build the Flutter iOS `.app` for the project in the current directory.
  ///
  /// Bundle id comes from `ios/Runner/Info.plist` / `project.pbxproj` (same
  /// sources Flutter tooling uses). Deletes any prior bundle, then packs.
  static Future<PackResult> pack({required FlutterBuildOptions options}) async {
    final projectRoot = Directory.current.path;
    final bundleId = IosBundleId.resolve(projectRoot);

    final packer = FlutterPacker(
      projectRoot: projectRoot,
      bundleId: bundleId,
      options: options,
    );

    // Always delete any previous bundle BEFORE packing, otherwise stale
    // binaries from an earlier build get codesigned into the new one.
    final bundleDir = Directory(
      p.join(projectRoot, 'build', 'xcross-ios', '${packer.appName}.app'),
    );
    if (bundleDir.existsSync()) await bundleDir.delete(recursive: true);

    final appPath = await packer.pack();
    return PackResult(outputPath: appPath, bundleId: bundleId);
  }
}
