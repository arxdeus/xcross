import 'dart:io';

import 'package:cli_kit/cli_kit_shared.dart';
import 'package:xcross/src/shared/flutter/swiftpm/artifact_filesystem.dart';
import 'package:xcross/src/shared/flutter/swiftpm/checkout_attributes.dart';

final class WindowsSwiftPmCheckoutAttributes
    implements SwiftPmCheckoutAttributes {
  WindowsSwiftPmCheckoutAttributes(this.runner, {required this.fileSystem});
  final ProcessRunner runner;
  final SwiftPmArtifactFileSystem fileSystem;
  @override
  Future<void> clear(String path) async {
    if (fileSystem.typeSync(path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final result = await runner.run(await runner.locateTool('attrib'), [
      '-R',
      path,
    ]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not clear read-only checkout placeholder: ${result.stderr}',
        path,
      );
    }
  }
}
